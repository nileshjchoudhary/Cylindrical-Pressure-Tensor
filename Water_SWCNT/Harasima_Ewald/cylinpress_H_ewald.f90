! ==========================================================================
! This version is for calculating molecular axial pressure of water in a single-wall 
! carbon nanotube by the Harasima/Ewald method
!  Note: 
!  1. Lennard-Jones potential is cut in the real space;
!  2. Coulombic interaction is treated by the Ewald method;
!     rcelect and alpha is pre-specified 
!     kmax = alpha*max[boxlength]/Pi*sqrt(-ln(ewld_prec))
!  3. No impulsive contribution to the (LJ) pressure for MD simulation;
!  4. Input file is DCD coordiantes from MD (LAMMPS) simulation;
!  5. PBC has been applied in the pressure calculation;
!  6. The COM position of nanotube is assumed fixed in the center of the box (z=0);
!  
! Author: Kaihang Shi
! Last update: Nov. 4, 2019
! ==========================================================================

PROGRAM virialpress_cylinder

Use global

IMPLICIT NONE

! ---------------- Define control variables ---------------------------!
! Control parameters 
Integer, Parameter :: st_frame = 1                   ! Starting frame
Integer, Parameter :: nd_frame = 1               ! End frame
! DCD file PATH 
Character*32, Parameter :: dcdpath = "/xxx/xxx/xxx/xxx.dcd"
! System parameter 
Double Precision, Parameter :: temp = 300.0d0       ! [Kelvin]
Integer, Parameter :: n_mol_types = 1               ! number of molecule types for DENSITY calculations
Integer, Parameter :: n_mol_tot = 7500              ! total number of water molecules in the system
Integer, Parameter :: n_sites_tot = 22500            ! Total number of atoms in all water molecules 
Integer, Parameter :: n_mol_sites = 3               ! number of sites in the water molecule
! External macromolecule (single-wall carbon nanotube)
Logical, Parameter :: ltube = .true.                 ! If there is an nanotube in the system?
Integer, Parameter :: n_sites_nt = 2000              ! Total number of atoms in the nanotube
Double Precision, Parameter :: radi_nt = 13.565d0       ! Radius of the nanotube [Angstrom]; used for acceleration of simulation
Double Precision, Parameter :: hlflen_nt = 30.129d0       ! Half length of the nanotube [Angstrom]; used for acceleration of simulation  
! LJ parameters 
Double Precision, Parameter :: sigma_co = 3.1900d0     ! cross-sigma for oxygen-carbon interaction [Angstrom]
Double Precision, Parameter :: epsilonkb_co = 47.1470064248d0 ! cross interaction for oxygen-carbon [Kelvin]
Double Precision, Parameter :: sigma_oo = 3.166d0      ! sigma for oxygen-oxygen interaction [Angstrom] 
Double Precision, Parameter :: epsilonkb_oo = 78.177560234d0  ! for oxygen-oxygen interaction [Kelvin]
Double Precision, Parameter :: r_ljcut = 10.0d0     ! LJ cutoff radius [Angstrom]
! Ewald parameters
Double Precision, Parameter :: alp = 0.3077d0          ! alpha (or keppa) parameter in real space [1/Angstrom]
Double Precision, Parameter :: r_coulcut = 10.0d0     ! real space cutoff for coulombic interaction [Angstrom]
Double Precision, Parameter :: ewld_prec = 1.0d-5     ! Corresponds to the absolute precision in LAMMPS (ver. 12Dec2018) 
! Mass
Double Precision, Parameter :: mol_mass = 18.01528d0  ! molecular weight of water [g/mol]
Double Precision, Parameter :: mass_o = 15.999400
Double Precision, Parameter :: mass_h = 1.007940
! Coulombic parameter
Double Precision, Parameter :: q_o = -0.8476d0    ! point charge for O [e]
Double Precision, Parameter :: q_h = 0.4238       ! point charge for H [e]
! Parameters of defined cylindrical geometry for sampling
Double Precision, Parameter :: rden_cut = 24.5d0   ! Cutoff distance for density/pressure calculation [Angstrom]
Integer, Parameter :: rden_bins = 800              ! density profile resolution
Double Precision, Parameter :: kavg = 0.2          ! L = Lz * kavg; where Lz is the box dimension in z-axis and L is the height of cylinder
Double Precision, Parameter :: cylrz = 0.0d0       ! COM z-position of the defined cylinder where sampling is performed 


! --------------- Define basic variables -------------------------------!
! Read in parameter
Character(len=128):: dummy
Character*4 :: dummyc
Character(len=128) :: site_name
Double Precision :: dummyr 
Integer :: dummyi
Integer :: frame_id, dcdframes, ns_frame, c_frame
Integer :: natom, natom_calc
! delta value in equation for Harasima contour use
Double Precision :: delrr
! r-density statistics (Density profile of each molecule type in the cylindrical system)
! Cutoff radius for density and cylindrical pressure tensor calculation
! limit in radial direction
Double Precision :: rden_lim
! r-density length in r direction for each bin
Double Precision :: rden_dr, rden_drsq
! Statistics 
Double Precision, Dimension(:,:), Allocatable :: rdenavg
Double Precision, Dimension(:,:,:), Allocatable :: rdenblk
! Averaing region in z-direction (axial direction of the cylinder)
Double Precision :: zlo, zhi
!Variables for pressure calculation
INTEGER :: imol, jmol, ibin, iframe, idirec, ierr, isol
INTEGER :: isite, jsite, itype, jtype, isitetype, jsitetype
DOUBLE PRECISION :: rxi, ryi, rzi, rijsq, rxj, ryj, rzj, xij, yij, zij, rxii, ryii, rzii, rxjj, ryjj, rzjj
DOUBLE PRECISION :: rxis, ryis, rzis, rxjs, ryjs, rzjs
DOUBLE PRECISION :: sr3, sr6, sr12, phitz, dudr_elec, dudr_lj
DOUBLE PRECISION :: ptzc_lj, ptzc_elec, ptzf
DOUBLE PRECISION :: rijs, xijs, yijs, zijs, rijssq
DOUBLE PRECISION :: xijssq, yijssq, zijssq, xijsq, yijsq, zijsq
Double Precision :: clri, clrj, clrij, posr, clrk, zlk, clris, clrjs
Double Precision :: clr, clrsq, rden_dvol
! CPU time
Double Precision :: cpu_st, cpu_nd
! ------------------------------------------------------------------------! 

! ---- Initialize basic parameters -----!
! specify the maxk
maxk = 8*40**3
! Assign input parameter to global variables for later use
alpha = alp
rcelect = r_coulcut
rcelectsq = (rcelect+2.0d0)**2
! Total number of frames for sampling
ns_frame = nd_frame - st_frame + 1
! r_ljcut is hard-coded smaller than r_coulcut
If (r_ljcut .GT. r_coulcut) Then
  Write(*,*) 'r_ljcut should be smaller than r_coulcut. Otherwise, revise the code!!'
  STOP
End IF

! -------- Allocate variables ----------!
Allocate(box(3,ns_frame), STAT=ierr)
Allocate(boxangle(3,ns_frame), STAT=ierr)
Allocate(volbox(ns_frame), STAT=ierr)
Allocate(rx_s(n_mol_sites,n_mol_tot,ns_frame), STAT=ierr)
Allocate(ry_s(n_mol_sites,n_mol_tot,ns_frame), STAT=ierr)
Allocate(rz_s(n_mol_sites,n_mol_tot,ns_frame), STAT=ierr)
Allocate(rxs_temp(n_sites_tot), STAT=ierr)
Allocate(rys_temp(n_sites_tot), STAT=ierr)
Allocate(rzs_temp(n_sites_tot), STAT=ierr)
Allocate(rx(n_mol_tot,ns_frame), STAT=ierr)
Allocate(ry(n_mol_tot,ns_frame), STAT=ierr)
Allocate(rz(n_mol_tot,ns_frame), STAT=ierr)
Allocate(rx_snt(n_sites_nt), STAT=ierr)
Allocate(ry_snt(n_sites_nt), STAT=ierr)
Allocate(rz_snt(n_sites_nt), STAT=ierr)
Allocate(virialpress_cylin_ptz(2,3,rden_bins), STAT=ierr) 
Allocate(virialptzavg(2,3,rden_bins), STAT=ierr) 
Allocate(prkin(rden_bins), STAT=ierr) 
Allocate(rdenavg(rden_bins,n_mol_types), STAT=ierr) 
Allocate(rdenblk(rden_bins,n_mol_types,ns_frame), STAT=ierr) 
! Ewald parameters
ALLOCATE(k_vec(2,maxk), STAT=ierr)
ALLOCATE(eikx(n_mol_tot,n_mol_sites,-40:40), STAT=ierr)
ALLOCATE(eiky(n_mol_tot,n_mol_sites,-40:40), STAT=ierr)
ALLOCATE(eikz(n_mol_tot,n_mol_sites,-40:40), STAT=ierr)
ALLOCATE(skewld(maxk), STAT=ierr)
ALLOCATE(skewlds(maxk), STAT=ierr)



! -- Initialize parameter -----!
virialpress_cylin_ptz = 0.0d0
virialptzavg = 0.0d0
prkin = 0.0d0
rdenavg = 0.0d0
rdenblk = 0.0d0
rden_dr = rden_cut/DBLE(rden_bins)
rden_drsq = rden_dr**2
delrr = rden_dr/2.0d0
rx = 0.0d0
ry = 0.0d0
rz = 0.0d0
rx_nt = 0.0d0
ry_nt = 0.0d0
rz_nt = 0.0d0


! Open file recording progress 
Open(5,File='progress',action='write', status='replace')

! ----------------- Read in coordinates from LAMMPS DCD format file ----------------!
Open(1,File=dcdpath,Status='Old', Form= 'unformatted')

! Read header
Read(1) dummyc, dcdframes, (dummyi,idirec=1,8), dummyr, (dummyi,idirec=1,9)
Read(1) dummyi, dummyr
Read(1) natom

! Check if there is a nanotube in the system
If(ltube) Then
  natom_calc = n_sites_tot + n_sites_nt
Else 
  natom_calc = n_sites_tot
End If 

! Make sure this run is sensible
If (natom_calc .NE. natom) Then
  Write(*,*) 'natom_calc is not equal to natom in DCD file!'
    STOP
End If

! Initialize counter
c_frame = 1

! Loop over pre-specified frames 
Do iframe = 1, nd_frame
  
  If (iframe .GE. st_frame) Then

    ! Read in box dimension
    Read(1) box(1,c_frame), boxangle(1,c_frame), box(2,c_frame), (boxangle(idirec,c_frame), idirec=2,3), box(3,c_frame)

    ! Set up box volume [A^3]
    volbox(c_frame) = box(1,c_frame)*box(2,c_frame)*box(3,c_frame)

    If ((rcelect+2.0d0) .GT. Min(box(1,c_frame),box(2,c_frame))/2.0d0) Then
      Write(5,*) 'Cutoff is too large for this box size!'
      STOP
    End If

  Else

    Read(1) (dummyr,idirec=1,6)

  ENDIF


  ! Convert cos value to degree angle
  !Do idirec = 1,3
  ! boxangle(idirec,iframe) = ACOS(boxangle(idirec,iframe))*180.0d0/Pi
  !EndDo

  ! ! Now PBC has applied in pressure calculations
  ! If (rden_cut .GT. Min(box(1,iframe),box(2,iframe))/4.0d0) Then
  !   Write(*,*) 'rden_cut is too large for this box size!'
  !   STOP
  ! End If

  If(ltube) Then
    ! Read in coordinates of nanotube and water molecules [REAL format]
    Read(1) (rx_snt(isite), isite=1,n_sites_nt), (rxs_temp(isite), isite=1,n_sites_tot)
    Read(1) (ry_snt(isite), isite=1,n_sites_nt), (rys_temp(isite), isite=1,n_sites_tot)
    Read(1) (rz_snt(isite), isite=1,n_sites_nt), (rzs_temp(isite), isite=1,n_sites_tot)
  Else
    ! No tube, directly read in water atom coordinates
    Read(1) (rxs_temp(isite), isite=1,n_sites_tot)
    Read(1) (rys_temp(isite), isite=1,n_sites_tot)
    Read(1) (rzs_temp(isite), isite=1,n_sites_tot)
  End If 


  If (iframe .LT. st_frame) CYCLE

  ! Reassign coordinates into new array according to the XYZ structure for this system
  jsite = 1
  Do imol = 1, n_mol_tot
    Do isite = 1, n_mol_sites

      ! -------------------------------------------------------------------------
      !!!! Notice: isite = 1 represents 'O' atom, isite = 2,3 represent 'H' atom
      ! -------------------------------------------------------------------------
      
      rx_s(isite,imol,c_frame) = rxs_temp(jsite)
      ry_s(isite,imol,c_frame) = rys_temp(jsite) 
      rz_s(isite,imol,c_frame) = rzs_temp(jsite)

      jsite = jsite + 1 
    End do
  End Do

  ! Calculate center of mass position of water molecules (considering PBC)
  Do imol = 1, n_mol_tot
    ! First hydrogen
    rxis = rx_s(2,imol,c_frame) - dNINT((rx_s(2,imol,c_frame)-rx_s(1,imol,c_frame))/box(1,c_frame))*box(1,c_frame)
    ryis = ry_s(2,imol,c_frame) - dNINT((ry_s(2,imol,c_frame)-ry_s(1,imol,c_frame))/box(2,c_frame))*box(2,c_frame)
    rzis = rz_s(2,imol,c_frame) - dNINT((rz_s(2,imol,c_frame)-rz_s(1,imol,c_frame))/box(3,c_frame))*box(3,c_frame)
    ! Second hydrogen
    rxjs = rx_s(3,imol,c_frame) - dNINT((rx_s(3,imol,c_frame)-rx_s(1,imol,c_frame))/box(1,c_frame))*box(1,c_frame)
    ryjs = ry_s(3,imol,c_frame) - dNINT((ry_s(3,imol,c_frame)-ry_s(1,imol,c_frame))/box(2,c_frame))*box(2,c_frame)
    rzjs = rz_s(3,imol,c_frame) - dNINT((rz_s(3,imol,c_frame)-rz_s(1,imol,c_frame))/box(3,c_frame))*box(3,c_frame)
    ! COM
    rx(imol,c_frame) = (rx_s(1,imol,c_frame)*mass_o + (rxis+rxjs)*mass_h)/(mass_o+2.0*mass_h)
    ry(imol,c_frame) = (ry_s(1,imol,c_frame)*mass_o + (ryis+ryjs)*mass_h)/(mass_o+2.0*mass_h)
    rz(imol,c_frame) = (rz_s(1,imol,c_frame)*mass_o + (rzis+rzjs)*mass_h)/(mass_o+2.0*mass_h)
    ! Put COM into the central box
    rx(imol,c_frame) = rx(imol,c_frame) - dNINT(rx(imol,c_frame)/box(1,c_frame))*box(1,c_frame) 
    ry(imol,c_frame) = ry(imol,c_frame) - dNINT(ry(imol,c_frame)/box(2,c_frame))*box(2,c_frame) 
    rz(imol,c_frame) = rz(imol,c_frame) - dNINT(rz(imol,c_frame)/box(3,c_frame))*box(3,c_frame) 

  ! End reading imol
  EndDo

  ! Update counter
  c_frame = c_frame + 1 

! End reading specified frames
End Do 

! Close file
CLOSE(1)

Write(5,*) 'Finished reading coordinates and box information from DCD file!'

! unit=6 is screen
!Call FLUSH(6)

! ---- COM position of nanotube -------!
Do isite = 1, n_sites_nt
  rx_nt = rx_nt + rx_snt(isite)
  ry_nt = ry_nt + ry_snt(isite)
  rz_nt = rz_nt + rz_snt(isite)
End Do
rx_nt = rx_nt/DBLE(n_sites_nt)
ry_nt = ry_nt/DBLE(n_sites_nt)
rz_nt = rz_nt/DBLE(n_sites_nt)
Write(5,*) 'COM position of nanotube: ',rx_nt, ry_nt, rz_nt
FLUSH(5)
! ------

! ! TEST coordiantes processing
! OPEN(2,FILE='testatom.XYZ', STATUS='UNKNOWN',ACCESS='SEQUENTIAL',ACTION='WRITE')
! OPEN(3,FILE='testmol.XYZ', STATUS='UNKNOWN',ACCESS='SEQUENTIAL',ACTION='WRITE')
! Write(2,*) dummyc, dcdframes,natom
! Do iframe = 1, 1
!   Write(2,*) box(1,iframe), box(2,iframe), box(3,iframe), boxangle(1,iframe), boxangle(2,iframe), boxangle(3,iframe)
!   Do imol = 1, n_mol_tot
!     Write (3,'(A,F15.7,F15.7,F15.7)') 'O', rx(imol,iframe), ry(imol,iframe), rz(imol,iframe)

!     Do isite = 1, n_mol_sites

!       ! Write to file
!       Write(2,*)  rx_s(isite,imol,iframe), ry_s(isite,imol,iframe), rz_s(isite,imol,iframe)
!     End Do
!   End do
! End Do

! ! Close file
! CLOSE(2)
! CLOSE(3)
! STOP

! ----------------------------- Start postprocessing -----------------------------!
! Call CPU time
Call CPU_TIME(cpu_st)

! Loop over frames
Do iframe = 1, ns_frame

  ! Set up averaging region in axial direction
  zlo = -0.5d0*box(3,iframe)*kavg + cylrz 
  zhi =  0.5d0*box(3,iframe)*kavg + cylrz
  
  ! ----------- Sampling molecular r-density ------------!
  ! Loop over all molecules
  Do imol = 1, n_mol_tot

    ! Only sampling over particles within [zlo,zhi]
    if((rz(imol,iframe) .ge. zlo) .AND. (rz(imol,iframe) .le. zhi)) Then

      ! Calculate r-distance of imol in cylindrical coordiantes
      clrsq = rx(imol,iframe)**2 + ry(imol,iframe)**2
      clr = dSQRT(clrsq)

      If (clr .LT. rden_cut) Then
        ! Calculate ibin number
        ibin = FLOOR(clr/rden_dr) + 1

        ! Accumulate number 
        rdenblk(ibin,1,iframe) = rdenblk(ibin,1,iframe) + 1.0d0
      End If
    ENDIF

  ! End loop over all molecules 
  End Do

  ! Loop over bins
  Do ibin = 1, rden_bins
    ! Loop over molecule types
    Do itype = 1, n_mol_types

      ! Calculate volume for each bin (changing in NPT ensemble)
      rden_dvol = Pi*DBLE(2*ibin-1)*(zhi-zlo)*rden_drsq

      ! Convert to number density (1/A^3)
      rdenavg(ibin,itype) = rdenavg(ibin,itype) + rdenblk(ibin,itype,iframe)/rden_dvol

    End Do          
  End Do  
  

  ! ----------- Sampling cylindrical pressure tensor ----------!   
  ! Set up ewald parameters every frames due to the change of box size
  Call set_ewld(ewld_prec,q_o,q_h,n_mol_sites,n_mol_tot,iframe)

  ! ------------------------ REAL SPACE ------------------------!

  ! ------ Fluid-Fluid interactions ----!
  ! Loop over all water molecules
  Do imol = 1, n_mol_tot - 1

    rxi = rx(imol,iframe)
    ryi = ry(imol,iframe)
    rzi = rz(imol,iframe)

    ! Calculate R-distance of molecule i in cylindrical coordiantes
    clri = dSQRT(rxi**2 + ryi**2)

    Do jmol = imol + 1, n_mol_tot

      rxj = rx(jmol,iframe)
      ryj = ry(jmol,iframe)
      rzj = rz(jmol,iframe)

      ! Calculate R-distance of molecule j 
      clrj = dSQRT(rxj**2+ryj**2)

      ! Check if continue
      If((clri .GT. rden_cut) .AND. (clrj .GT. rden_cut)) CYCLE
      If((rzi .LT. zlo) .AND. (rzj .LT. zlo)) CYCLE
      If((rzi .GT. zhi) .AND. (rzj .GT. zhi)) CYCLE
      If((rzi .GT. zhi) .AND. (rzj .LT. zlo)) CYCLE
      If((rzi .LT. zlo) .AND. (rzj .GT. zhi)) CYCLE

      ! Separation vector
      xij = rxj - rxi
      yij = ryj - ryi
      zij = rzj - rzi

      ! Apply minimum image convention
      xij = xij - dNINT(xij/box(1,iframe))*box(1,iframe)
      yij = yij - dNINT(yij/box(2,iframe))*box(2,iframe)
      zij = zij - dNINT(zij/box(3,iframe))*box(3,iframe)

      xijsq = xij*xij
      yijsq = yij*yij
      zijsq = zij*zij

      rijsq = xijsq + yijsq + zijsq

      If (rijsq .GT. rcelectsq) CYCLE

      ! Initialize ptzc variables
      ptzc_lj = 0.0d0
      ptzc_elec = 0.0d0

      ! Loop over sites
      DO isite = 1, n_mol_sites

        rxis = rx_s(isite,imol,iframe) 
        ryis = ry_s(isite,imol,iframe) 
        rzis = rz_s(isite,imol,iframe)

        Do jsite = 1, n_mol_sites

          rxjs = rx_s(jsite,jmol,iframe)
          ryjs = ry_s(jsite,jmol,iframe)
          rzjs = rz_s(jsite,jmol,iframe)

          !Calculate vector between sites
          xijs = rxjs - rxis
          yijs = ryjs - ryis
          zijs = rzjs - rzis

          ! Apply minimum image convention
          xijs = xijs - dNINT(xijs/box(1,iframe))*box(1,iframe)
          yijs = yijs - dNINT(yijs/box(2,iframe))*box(2,iframe)
          zijs = zijs - dNINT(zijs/box(3,iframe))*box(3,iframe)

          !Square the values
          xijssq=xijs*xijs
          yijssq=yijs*yijs
          zijssq=zijs*zijs

          rijssq = xijssq+yijssq+zijssq

          !Calculate distance between i and j sites
          rijs=dSQRT(rijssq)

          ! assuming r_coulcut > r_ljcut always
          If (rijs .GT. rcelect) CYCLE

          ! Determine interaction
          If((isite .eq. 1) .and. (jsite .eq. 1)) Then

            ! O-O interaction
            If (rijs .GT. r_ljcut) Then

              ! Only real-space damped coulombic interaction [K/A]
              dudr_elec = - q_o**2 * (2.0*alpha*dEXP(-alpha**2*rijssq)/(sqrtPi*rijs) + dERFC(alpha*rijs)/rijssq)*EETOK
              dudr_lj = 0.0d0

            Else

              !Calculate 12-6LJ force (based on sites)
              sr3=(sigma_oo/rijs)**3
              sr6=sr3*sr3
              sr12=sr6*sr6
              phitz = 24.0*epsilonkb_oo/rijs
              dudr_lj = phitz*(sr6 - 2.0d0*sr12)

              ! Calculate Coulombic force [K/A]
              dudr_elec = - q_o**2 * (2.0*alpha*dEXP(-alpha**2*rijssq)/(sqrtPi*rijs) + dERFC(alpha*rijs)/rijssq)*EETOK
              
            End If

          Else if ( (isite .GT. 1) .AND. (jsite .GT. 1)) Then
            ! H - H interaction [K/A]
            dudr_elec = - q_h**2 * (2.0*alpha*dEXP(-alpha**2*rijssq)/(sqrtPi*rijs) + dERFC(alpha*rijs)/rijssq)*EETOK
            dudr_lj = 0.0d0

          Else 
            ! O - H interaction [K/A]
            dudr_elec = - q_o*q_h * (2.0*alpha*dEXP(-alpha**2*rijssq)/(sqrtPi*rijs) + dERFC(alpha*rijs)/rijssq)*EETOK
            dudr_lj = 0.0d0

          End if

          ! == Harasima definition ==
          ! Calculate axial tangential pressure in z-direction
          ptzc_lj = ptzc_lj + 0.5d0*dudr_lj*zij*zijs/(rijs*(zhi-zlo))
          ptzc_elec = ptzc_elec + 0.5d0*dudr_elec*zij*zijs/(rijs*(zhi-zlo))

        ! End jsite
        End Do 
      ! End isite
      End Do


      !Loop through the bins
      DO ibin= 1, rden_bins

        ! Get r-distance of ibin in cylindrical system
        posr = (DBLE(ibin)-0.5d0)*rden_dr

        ! P_zz
        ! unit step function
        ! Half contribute to molecule i
        If ((posr-clri+delrr) .gt. 0.0d0) Then
          If ((clri+delrr-posr) .gt. 0.0d0) Then
            if((rzi .ge. zlo) .and. (rzi .le. zhi)) Then

              virialpress_cylin_ptz(2,1,ibin) = virialpress_cylin_ptz(2,1,ibin) + ptzc_elec
              virialpress_cylin_ptz(2,3,ibin) = virialpress_cylin_ptz(2,3,ibin) + ptzc_lj


            End If
          End If
        End If

        ! unit step function
        ! Half contribute to molecule j
        If ((posr-clrj+delrr) .gt. 0.0d0) Then
          If ((clrj+delrr-posr) .gt. 0.0d0) Then
            if((rzj .ge. zlo) .and. (rzj .le. zhi)) Then

              virialpress_cylin_ptz(2,1,ibin) = virialpress_cylin_ptz(2,1,ibin) + ptzc_elec
              virialpress_cylin_ptz(2,3,ibin) = virialpress_cylin_ptz(2,3,ibin) + ptzc_lj

            End If
          End If
        End If

      !End bin cycle
      ENDDO

    !End loop over jmol sites 
    ENDDO          
  !End loop over imol sites
  ENDDO  
  ! -----------------------------------!

  ! ------ Fluid-Wall interactions ----!
  If(ltube) Then

    ! Loop over all water molecules
    Do imol = 1, n_mol_tot

      rxi = rx(imol,iframe)
      ryi = ry(imol,iframe)
      rzi = rz(imol,iframe)

      ! Calculate R-distance of molecule i in cylindrical coordiantes
      clri = dSQRT(rxi**2 + ryi**2)

      ! Only oxygen atom (isite=1) interacts with the nanotube
      rxis = rx_s(1,imol,iframe) 
      ryis = ry_s(1,imol,iframe) 
      rzis = rz_s(1,imol,iframe)

      ! Calculate R-distance of oxygen atom to skip some iterations
      clris = dSQRT(rxis**2 + ryis**2)

      ! Assuming the COM of the nanotube is at box origin, i.e., x=y=z=0
      ! Quick check if to continue (Only LJ interaction matters for fluid-wall case)
      If(clris .LT. (radi_nt - r_ljcut)) CYCLE
      If(clris .GT. (radi_nt + r_ljcut + 1.0)) CYCLE  ! 1.0 is a buffer value
      If(rzis .GT. (zhi + r_ljcut)) CYCLE
      If(rzis .LT. (zlo - r_ljcut)) CYCLE

      ! Loop over nanotube atoms 
      Do jsite = 1, n_sites_nt

        rxjs = rx_snt(jsite)
        ryjs = ry_snt(jsite)
        rzjs = rz_snt(jsite)

        ! Exclude non-interacting nanotube atoms
        If(rzjs .GT. (rzis+r_ljcut)) CYCLE
        If(rzjs .LT. (rzis-r_ljcut)) CYCLE
        ! Excluding pairs that do not contribute to the pressure in averaing region
        If((rzi .GT. zhi) .and. (rzjs .GT. zhi)) CYCLE
        If((rzi .LT. zlo) .and. (rzjs .LT. zlo)) CYCLE

        !Calculate vector between sites
        xijs = rxjs - rxis
        yijs = ryjs - ryis
        zijs = rzjs - rzis

        ! Apply minimum image convention
        xijs = xijs - dNINT(xijs/box(1,iframe))*box(1,iframe)
        yijs = yijs - dNINT(yijs/box(2,iframe))*box(2,iframe)
        zijs = zijs - dNINT(zijs/box(3,iframe))*box(3,iframe)

        !Square the values
        xijssq=xijs*xijs
        yijssq=yijs*yijs
        zijssq=zijs*zijs

        rijssq = xijssq+yijssq+zijssq

        !Calculate distance between i and j sites
        rijs=dSQRT(rijssq)

        ! cutoff radius
        If (rijs .GT. r_ljcut) CYCLE

        ! Determine interaction
        !Calculate 12-6LJ force (based on sites)
        sr3=(sigma_co/rijs)**3
        sr6=sr3*sr3
        sr12=sr6*sr6
        phitz = 24.0*epsilonkb_co/rijs
        dudr_lj = phitz*(sr6 - 2.0d0*sr12)

        ! R-distance of nanotube atoms
        clrjs = dSQRT(rxjs**2 + ryjs**2)

        ! Molecular separation vector
        zij = rzjs - rzi

        ! Apply minimum image convention
        zij = zij - dNINT(zij/box(3,iframe))*box(3,iframe)

        ! == Harasima definition ==
        ! Calculate axial tangential pressure in z-direction
        ptzc_lj = 0.5d0*dudr_lj*zij*zijs/(rijs*(zhi-zlo))

        !Loop through the bins
        DO ibin= 1, rden_bins

          ! Get r-distance of ibin in cylindrical system
          posr = (DBLE(ibin)-0.5d0)*rden_dr

          ! P_zz
          ! unit step function
          ! Half contribute to molecule i
          If ((posr-clri+delrr) .gt. 0.0d0) Then
            If ((clri+delrr-posr) .gt. 0.0d0) Then
              if((rzi .ge. zlo) .and. (rzi .le. zhi)) Then

                virialpress_cylin_ptz(1,3,ibin) = virialpress_cylin_ptz(1,3,ibin) + ptzc_lj

              End If
            End If
          End If

          ! Half contribute to nanotube atoms 
          If ((posr-clrjs+delrr) .gt. 0.0d0) Then
            If ((clrjs+delrr-posr) .gt. 0.0d0) Then
              if((rzjs .ge. zlo) .and. (rzjs .le. zhi)) Then

                virialpress_cylin_ptz(1,3,ibin) = virialpress_cylin_ptz(1,3,ibin) + ptzc_lj

              End If
            End If
          End If

        !End bin cycle
        ENDDO

      ! End jsite on nanotube
      End Do
      
    !End loop over imol sites
    ENDDO

  End If 

  ! ----------------End Real space -----------------!


  ! --------------- RECIPROCAL SPACE ---------------!
  Do imol = 1, n_mol_tot 

    rxi = rx(imol,iframe)
    ryi = ry(imol,iframe)
    rzi = rz(imol,iframe)

    ! Calculate R-distance of molecule i in cylindrical coordiantes
    clri = dSQRT(rxi**2 + ryi**2)

    If (clri .GE. rden_cut) CYCLE
    If (rzi .LT. zlo) CYCLE
    If (rzi .GT. zhi) CYCLE

    ! Call subroutine to calculate axial pressure from reciprocal contribution
    Call ewld_mol(q_o,q_h,n_mol_sites,n_mol_tot,imol,iframe,ptzf)

    ! Convert units to [K/A]
    ptzf = 0.5d0* ptzf * 2.0d0*two_Pi/(volbox(iframe)*(zhi-zlo)) * EETOK


    !Loop through the bins
    DO ibin= 1, rden_bins

      ! Get r-distance of ibin in cylindrical system
      posr = (DBLE(ibin)-0.5d0)*rden_dr

      ! P_zz
      ! unit step function
      ! Half contribute to molecule i
      If ((posr-clri+delrr) .gt. 0.0d0) Then
        If ((clri+delrr-posr) .gt. 0.0d0) Then

            virialpress_cylin_ptz(2,2,ibin) = virialpress_cylin_ptz(2,2,ibin) + ptzf

        End If
      End If

    !End bin cycle
    ENDDO

  ! End loop over imol
  End Do

  Close(5)


  ! write progress
  If(MOD(iframe,10) .eq. 0) Then
    Call CPU_TIME(cpu_nd)
    Open(5,File='progress',action='write', status='replace')
    Write(5,'(A,I10,I5,I5,I5)') 'Finished sampling of frame #', st_frame+iframe-1, kxmax, kymax, kzmax 
    Write(5,'(A,F6.2,A)') 'Progress: ', DBLE(iframe)/DBLE(ns_frame)*100.0d0, '%'
    Write(5,'(A,F7.3,A,2X,F7.3,A)') 'Time left:', &
      & (cpu_nd - cpu_st)/DBLE(iframe)*DBLE(ns_frame-iframe)/3600.0, 'hours', &
      & (cpu_nd - cpu_st)/DBLE(iframe)*DBLE(ns_frame-iframe)/3600.0/24.0, 'days'
    FLUSH(5)
    Close(5)
  ENDIF

! End loop over frames
End do



! ---------------------- Average statistics and write statistics to file -----------------!
! ------------ Radial density --------------!
! Open file
OPEN(2,FILE='r-density.txt',STATUS='UNKNOWN',ACCESS='SEQUENTIAL',ACTION='WRITE')

! Loop over bins
Do ibin = 1, rden_bins
  ! Loop over molecule types
  Do itype = 1, n_mol_types

    rdenavg(ibin,itype) = rdenavg(ibin,itype)/DBLE(ns_frame)
      ! Convert unit from [1/A^3] to [g/ml]
      rdenavg(ibin,itype) = (mol_mass/(Na*1.0d-24))*rdenavg(ibin,itype)

  End Do
End Do

! Write data to file
! loop over molecule types
Do itype = 1, n_mol_types
  ! Write molecule info
  Write(2,*) ' R             R-rho [g/ml]           R-rho [1/A^3]'

  ! Loop over bins
  Do ibin = 1, rden_bins

    ! Write to file
    Write(2,'(F8.4,7X,E15.7,8X,E15.7)')  (DBLE(ibin)-0.5d0)*rden_dr, rdenavg(ibin,itype), &
                      & (rdenavg(ibin,itype)/mol_mass)*Na*1.0d-24
    
  End Do
End Do

! Close file
CLOSE(2)

! ------------ Cylindrical pressure tensor ----------------!
Do ibin = 1, rden_bins

  ! Pressure (Kinetic part) in unit of [K/A^3]
  prkin(ibin) = (rdenavg(ibin,1)/mol_mass)*Na*1.0d-24*temp

  ! Get r-distance of ibin in cylindrical system
  posr = (DBLE(ibin)-0.5d0)*rden_dr

  ! Harasima route
  ! Fluid-fluid contribution
  ! From real space (Coulombic)
  virialptzavg(2,1,ibin) = virialpress_cylin_ptz(2,1,ibin)/DBLE(ns_frame)
  ! From Fourier space
  virialptzavg(2,2,ibin) = virialpress_cylin_ptz(2,2,ibin)/DBLE(ns_frame)
  ! From LJ interactions
  virialptzavg(2,3,ibin) = virialpress_cylin_ptz(2,3,ibin)/DBLE(ns_frame)

  ! Fluid-wall contribution
  If(ltube) Then
    virialptzavg(1,3,ibin) = virialpress_cylin_ptz(1,3,ibin)/DBLE(ns_frame)
  ENDIF

  ! Calculate final pressure (configurational part) in unit of [K/A^3]
  ! Fluid-fluid
  virialptzavg(2,1,ibin) = -1.0d0/(two_Pi*posr*rden_dr)*virialptzavg(2,1,ibin)
  virialptzavg(2,2,ibin) = -1.0d0/(two_Pi*posr*rden_dr)*virialptzavg(2,2,ibin)
  virialptzavg(2,3,ibin) = -1.0d0/(two_Pi*posr*rden_dr)*virialptzavg(2,3,ibin)

  ! Fluid-wall
  If(ltube) virialptzavg(1,3,ibin) = -1.0d0/(two_Pi*posr*rden_dr)*virialptzavg(1,3,ibin)


End Do

! Open file
OPEN(3,FILE='press_cylinH.txt', STATUS='UNKNOWN',ACCESS='SEQUENTIAL',ACTION='WRITE')

! Write file head
Write(3,*) 'Cylindrical pressure tensor from virial route using the Harasima definition'
Write(3,*) 'Unit: pressure in [bar] and length in [Angstrom]'
Write(3,'(A)') &
 & '  R              Pkin        Ptz(ff_real)        Ptz(ff_Fourier)        Ptz(ff_LJ)        Ptz(fw_LJ)       Ptz(tot)'

! Write data to file
! Loop over bins
Do ibin = 1, rden_bins

  ! Write to file
  Write(3,'(F8.4,F16.4,F16.4,3X,F16.4,6X,F16.4,3X,F16.4,3X,F16.4)')  &
    & (DBLE(ibin)-0.5d0)*rden_dr, prkin(ibin)*PCOEFF, &
    & virialptzavg(2,1,ibin)*PCOEFF, &
    & virialptzavg(2,2,ibin)*PCOEFF, &
    & virialptzavg(2,3,ibin)*PCOEFF, &
    & virialptzavg(1,3,ibin)*PCOEFF, &
    & (prkin(ibin)+virialptzavg(2,1,ibin)+virialptzavg(2,2,ibin)+virialptzavg(2,3,ibin)+virialptzavg(1,3,ibin))*PCOEFF


End Do

! Close file
CLOSE(3)




! ---------- Deallocate variables to free space -------------!
Deallocate(box)
Deallocate(boxangle)
Deallocate(volbox)
Deallocate(rx_s)
Deallocate(ry_s)
Deallocate(rz_s)
Deallocate(rxs_temp)
Deallocate(rys_temp)
Deallocate(rzs_temp)
Deallocate(rx)
Deallocate(ry)
Deallocate(rz)
Deallocate(rx_snt)
Deallocate(ry_snt)
Deallocate(rz_snt)
Deallocate(virialpress_cylin_ptz) 
Deallocate(virialptzavg) 
Deallocate(prkin) 
Deallocate(rdenavg) 
Deallocate(rdenblk) 
Deallocate(k_vec)
Deallocate(eikx)
Deallocate(eiky)
Deallocate(eikz)
Deallocate(skewld)
Deallocate(skewlds)

  


END PROGRAM virialpress_cylinder
