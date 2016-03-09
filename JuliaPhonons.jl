module JuliaPhonons

export atomicmass
export read_POSCAR, read_meshyaml
export output_animated_xyz, decompose_eigenmode_atomtype, decompose_eigenmode_atom_contributions

import YAML

# This would be better in a general library!
atomicmass = Dict{AbstractString,Float64}(
"H"=>1.00794, "C" => 12.01, "N" => 14.01, "S" => 32.07, "Zn" => 65.38, 
"I" => 126.9, "Br" => 79.904, "Cl" => 35.45,
"Cs" => 132.0, "Pb" => 207.2)
#Zn is actually Sn; stupid work-around for Pymol seeing 'Sn' as 'S'
#The initial test cases which I am covering, are phonons of CH3NH3.PbI3 and SnS

type POSCARtype
    lattice
    natoms::Int
    species
    speciescount
    atomnames
    positions
    supercell
end
POSCARtype() = POSCARtype([],0,[],[],[],[],[]) #Eeek!

function read_POSCAR(f::IOStream)
# Native VASP POSCAR reader
    P=readdlm(f)
    POSCAR=POSCARtype()

    POSCAR.lattice=[ P[l,f]::Float64 for l=3:5,f=1:3 ]
    println(STDERR,POSCAR.lattice)
    POSCAR.species=[ P[6,f] for f=1:length(P[7,:]) ]
    POSCAR.speciescount=[ P[7,f]::Int for f=1:length(P[7,:]) ]
    POSCAR.natoms=sum(POSCAR.speciescount)
    println(STDERR,POSCAR.species)
    POSCAR.positions=[ P[l,f]::Float64 for l=9:9+POSCAR.natoms,f=1:3 ]
# The following is probably overkill, but reads the VASP atom formats + expands
# into a one dimensional string vector 
#     species:    C    N    H    Pb   I
#     speciescount:   1     1     6     1     3
    POSCAR.atomnames=AbstractString[]
    for (count,specie) in zip(POSCAR.speciescount,POSCAR.species)
        for i=1:count push!(POSCAR.atomnames,specie) end
    end
    println(STDERR,POSCAR.atomnames)

    # SUPERCELL definition. Should probably be somewhere else?
    POSCAR.supercell=[ a*POSCAR.lattice[1,:] + b*POSCAR.lattice[2,:] + c*POSCAR.lattice[3,:] for a=0:1,b=0:1,c=0:1 ] #generates set of lattice vectors to apply for supercell expansions
    println(STDERR,"supercellexpansions ==>",POSCAR.supercell)
    
    return POSCAR
end

function read_meshyaml(f::IOStream, P::POSCARtype)
    mesh = YAML.load(f)     #Phonopy mesh.yaml file; with phonons

    eigenvectors=[]
    eigenmodes=[]

# Data structure looks like: mesh["phonon"][1]["band"][2]["eigenvector"][1][2][1]
    for (eigenmode,(eigenvector,freq)) in enumerate(mesh["phonon"][1]["band"])
#    println("freq (THz) ==> ",freq[2], "\tWavenumbers (cm-1, 3sf) ==> ",freq[2]*33.36)

## These functions used when figuring out form / normalisation of eigenvectors, from Phonopy mesh.yaml
#    println("phonon[\"eigenvector\"] ==>",phonon["eigenvector"])
#    println("eigenvector ==> ",eigenvector[2])
#    for atom in eigenvector[2]
#        #println ("atom ==> ",atom)
#        @printf("atom %e %e %e \n",atom[1][1],atom[2][1],atom[3][1])
#        disp=[atom[1][1],atom[2][1],atom[3][1]] #pull data out of YAML into sensible Julia Vector
#        println(disp)
#    end

        realeigenvector=[ eigenvector[2][n][d][1]::Float64 for n=1:P.natoms, d=1:3 ]
        # Array comprehension to reform mesh.yaml format into [n][d] shap
        realeigenvector=reshape(realeigenvector,P.natoms,3) # doesn't do anything?

        push!(eigenvectors,realeigenvector)
        push!(eigenmodes,freq[2])
#        output_animated_xyz(P,eigenmode,realeigenvector,freq)

#        decompose_eigenmode_atomtype(P,eigenmode,realeigenvector,freq)
#        decompose_eigenmode_atom_contributions(P,eigenmode,realeigenvector)
    end

#    print(eigenvectors)
#    print(eigenmodes)

    return eigenvectors, eigenmodes
#    output_animated_xyz(P,42,eigenvectors[2],eigenmodes[2])
end


function output_animated_xyz(POSCAR::POSCARtype, eigenmode,eigenvector,freq,steps=32)
    filename= @sprintf("anim_%02d.xyz",eigenmode)
    anim=open(filename,"w")

    for phi=0:2*pi/steps:2*pi-1e-6 #slightly offset from 2pi so we don't repeat 0=2pi frame
#        projection= lattice[1][1]*positions + 2*realeigenvector*sin(phi) # this does all the maths
#        println("Lattice: ",lattice,"\n Eigenvec: ",realeigenvector)
        #projection=positions*lattice + 2*sin(phi)*realeigenvector
#        println("Projection: ",projection)

        # output routines to .xyz format
        @printf(anim,"%d\n\n",POSCAR.natoms*length(POSCAR.supercell)) # header for .xyz multi part files
        for i=1:POSCAR.natoms
#            println("u ==> ",projection[i,:])
#            println("Positions[",i,"]: ",positions[i,:])
#            println("Realeigenvector[",i,"]: ",realeigenvector[i,:])

# NB: Currently uncertain as to whether to apply mass weighting by:-
#   diving the eigenvector by sqrt(amu) - converting from Energy --> displacement
#   multiplying the eigenvector by sqrt(amu) - weighting the Dynamic matrix with atomic mass ?
            projection=POSCAR.lattice * (POSCAR.positions[i,:]' + 0.2 / sqrt(atomicmass[POSCAR.atomnames[i]]) * eigenvector[i,:]'*sin(phi))
            for supercellexpansion in POSCAR.supercell
                supercellprojection=projection+supercellexpansion'
                @printf(anim,"%s %f %f %f\n",POSCAR.atomnames[i],supercellprojection[1],supercellprojection[2],supercellprojection[3])
            end
        end
    end
    close(anim)


end

# This decomposes the amount that the different atomtypes contribute to each phonon mode, in the unit cell
function decompose_eigenmode_atomtype(POSCAR::POSCARtype,label,realeigenvector,freq)
    print("EnergyFraction Eigenmode: ",label)
    @printf("\tFreq: %.2f (THz) %03.1f (cm-1)\t",freq,freq*33.36)

    #atomiccontribution = Dict{AbstractString,Float64}("Pb"=>0.0, "Br" => 0.0, "N" => 0.0, "C" => 0.0, "H" => 0.0)
    atomiccontribution=[POSCAR.species[i]=>0.0 for i in 1:length(POSCAR.species)]
    for i=1:POSCAR.natoms
        atomiccontribution[POSCAR.atomnames[i]]+= norm(realeigenvector[i,:])
    end
   
    totallength=sum(values(atomiccontribution))
    # Now weight every object
    for contri in keys(atomiccontribution) # Surely a better way that iterating over?
        atomiccontribution[contri]/=totallength
    end

    for contri in sort(POSCAR.species, by=x->atomicmass[x],rev=true) #Heaviest first, by lookup 
        @printf("%s %.4f\t",contri,atomiccontribution[contri])
    end
#    println(atomiccontribution)
#    println(sum(values(atomiccontribution)))
    println()
end

# This outputs, for each atom in the unit cell, the contribution in terms of displacement and energy, for the phonon
function decompose_eigenmode_atom_contributions(POSCAR::POSCARtype,eigenmode,realeigenvector)
    normsum=0.0
    normsummassweighted=0.0
    for i=1:POSCAR.natoms
        normsum+=norm(realeigenvector[i,:])
        normsummassweighted+=norm(realeigenvector[i,:])/sqrt(atomicmass[POSCAR.atomnames[i]])
    end
    println("Normalising sum (Energy): ",normsum, " Normalising sum (Displacement): ",normsummassweighted)
    for i=1:POSCAR.natoms
        println("Mode: ",eigenmode," Atom: ",i," ",POSCAR.atomnames[i],
#        "\n",
#        " Norm: ", norm(realeigenvector[i,:]),
        "\t EnergyFraction: ",norm(realeigenvector[i,:])/normsum,
        "\t DisplacementFraction: ",(norm(realeigenvector[i,:])/sqrt(atomicmass[POSCAR.atomnames[i]]))/normsummassweighted)
    end
end 

# Header line for GNUPLOT, plotting mode decompositions.
function gnuplot_header()
    @printf("Mode 1 Freq THz THz cm1 cm1 ") 
    for contri in sort(species, by=x->atomicmass[x],rev=true) #Heaviest first, by lookup 
        @printf("%s %s\t",contri,contri)
    end
    @printf("\n")
end

# Defunct code?
#=    
    for I=10:12 # iodine indexes, hard coded
        println(show(positions))
        println(show(positions[I,:]))
        PbI=positions[I,:]-positions[9,:] # Vector from Pb to I
        show(PbI)
        @printf("I: %d PbI: %f %f %f Phonon-u: %f %f %f PbI.Phonon-u: %f\n",I,
        PbI[1],PbI[2],PbI[3],
        realeigenvector[I,1],realeigenvector[I,2],realeigenvector[I,3],
        dot(PbI::Float64,realeigenvector[I]::Float64) )
    end
=#

end
