! This code is part of Radiative Transfer for Energetics (RTE)
!
! Contacts: Robert Pincus and Eli Mlawer
! email:  rrtmgp@aer.com
!
! Copyright 2015-2018,  Atmospheric and Environmental Research and
! Regents of the University of Colorado.  All right reserved.
!
! Use and duplication is permitted under the terms of the
!    BSD 3-clause license, see http://opensource.org/licenses/BSD-3-Clause
! -------------------------------------------------------------------------------------------------
!
!  Contains a single routine to compute direct and diffuse fluxes of solar radiation given
!    atmospheric optical properties, spectrally-resolved
!    information about vertical ordering
!    internal Planck source functions, defined per g-point on the same spectral grid at the atmosphere
!    boundary conditions: surface emissivity defined per band
!    optionally, a boundary condition for incident diffuse radiation
!    optionally, an integer number of angles at which to do Gaussian quadrature if scattering is neglected
!
! If optical properties are supplied via class ty_optical_props_1scl (absorption optical thickenss only)
!    then an emission/absorption solver is called
!    If optical properties are supplied via class ty_optical_props_2str fluxes are computed via
!    two-stream calculations and adding.
!
! It is the user's responsibility to ensure that emissivity is on the same
!   spectral grid as the optical properties.
!
! Final output is via user-extensible ty_fluxes which must reduce the detailed spectral fluxes to
!   whatever summary the user needs.
!
! The routine does error checking and choses which lower-level kernel to invoke based on
!   what kinds of optical properties are supplied
!
! -------------------------------------------------------------------------------------------------
module mo_rte_lw
  use mo_rte_kind,      only: wp, wl
  use mo_optical_props, only: ty_optical_props, &
                              ty_optical_props_arry, ty_optical_props_1scl, ty_optical_props_2str, ty_optical_props_nstr
  use mo_source_functions,   &
                        only: ty_source_func_lw
  use mo_fluxes,        only: ty_fluxes
  use mo_rte_solver_kernels, &
                        only: apply_BC, lw_solver_noscat_GaussQuad, lw_solver_2stream
  implicit none
  private

  public :: rte_lw
contains
  ! --------------------------------------------------
  !
  ! Interface using only optical properties and source functions as inputs; fluxes as outputs.
  !
  ! --------------------------------------------------
  function rte_lw(optical_props, top_at_1, &
                  sources, sfc_emis,       &
                  fluxes,                  &
                  inc_flux, n_gauss_angles) result(error_msg)
    class(ty_optical_props_arry), intent(in   ) :: optical_props     ! Array of ty_optical_props. This type is abstract
                                                                     ! and needs to be made concrete, either as an array
                                                                     ! (class ty_optical_props_arry) or in some user-defined way
    logical,                      intent(in   ) :: top_at_1          ! Is the top of the domain at index 1?
                                                                     ! (if not, ordering is bottom-to-top)
    type(ty_source_func_lw),      intent(in   ) :: sources
    real(wp), dimension(:,:),     intent(in   ) :: sfc_emis    ! emissivity at surface [] (nband, ncol)
    class(ty_fluxes),             intent(inout) :: fluxes      ! Array of ty_fluxes. Default computes broadband fluxes at all levels
                                                               !   if output arrays are defined. Can be extended per user desires.
    real(wp), dimension(:,:),   &
              target, optional, intent(in   ) :: inc_flux    ! incident flux at domain top [W/m2] (ncol, ngpts)
    integer,          optional, intent(in   ) :: n_gauss_angles ! Number of angles used in Gaussian quadrature
                                                                ! (no-scattering solution)
    character(len=128)                        :: error_msg   ! If empty, calculation was successful
    ! --------------------------------
    !
    ! Local variables
    !
    integer :: ncol, nlay, ngpt, nband
    integer :: n_quad_angs
    integer :: icol, iband, igpt
    real(wp), dimension(:,:,:), allocatable :: gpt_flux_up, gpt_flux_dn
    real(wp), dimension(:,:),   allocatable :: sfc_emis_gpt
    ! --------------------------------------------------
    !
    ! Weights and angle secants for first order (k=1) Gaussian quadrature.
    !   Values from Table 2, Clough et al, 1992, doi:10.1029/92JD01419
    !   after Abramowitz & Stegun 1972, page 921
    !
    integer,  parameter :: max_gauss_pts = 4
    real(wp), parameter,                         &
      dimension(max_gauss_pts, max_gauss_pts) :: &
        gauss_Ds  = RESHAPE([1.66_wp,               0._wp,         0._wp,         0._wp, &  ! Diffusivity angle, not Gaussian angle
                             1.18350343_wp, 2.81649655_wp,         0._wp,         0._wp, &
                             1.09719858_wp, 1.69338507_wp, 4.70941630_wp,         0._wp, &
                             1.06056257_wp, 1.38282560_wp, 2.40148179_wp, 7.15513024_wp], &
                            [max_gauss_pts, max_gauss_pts]),              &
        gauss_wts = RESHAPE([0.5_wp,          0._wp,           0._wp,           0._wp, &
                             0.3180413817_wp, 0.1819586183_wp, 0._wp,           0._wp, &
                             0.2009319137_wp, 0.2292411064_wp, 0.0698269799_wp, 0._wp, &
                             0.1355069134_wp, 0.2034645680_wp, 0.1298475476_wp, 0.0311809710_wp], &
                             [max_gauss_pts, max_gauss_pts])
    ! ------------------------------------------------------------------------------------
    !
    ! Error checking
    !   if inc_flux is present it has the right dimensions, is positive definite
    !
    ! --------------------------------
    ncol  = optical_props%get_ncol()
    nlay  = optical_props%get_nlay()
    ngpt  = optical_props%get_ngpt()
    nband = optical_props%get_nband()
    error_msg = ""

    ! ------------------------------------------------------------------------------------
    !
    ! Error checking -- consistency of sizes and validity of values
    !
    ! --------------------------------
    if(.not. fluxes%are_desired()) then
      error_msg = "rte_lw: no space allocated for fluxes"
      return
    end if

    !
    ! Source functions
    !
    if(any([sources%get_ncol(), sources%get_nlay(), sources%get_ngpt()]  /= [ncol, nlay, ngpt])) &
      error_msg = "rte_lw: sources and optical properties inconsistently sized"
    ! Also need to validate

    !
    ! Surface emissivity
    !
    if(any([size(sfc_emis,1), size(sfc_emis,2)] /= [nband, ncol])) &
      error_msg = "rte_lw: sfc_emis inconsistently sized"
    if(any(sfc_emis < 0._wp .or. sfc_emis > 1._wp)) &
      error_msg = "rte_lw: sfc_emis has values < 0 or > 1"
    if(len_trim(error_msg) > 0) return

    !
    ! Incident flux, if present
    !
    if(present(inc_flux)) then
      if(any([size(inc_flux,1), size(inc_flux,2)] /= [ncol, ngpt])) &
        error_msg = "rte_lw: inc_flux inconsistently sized"
      if(any(inc_flux < 0._wp)) &
        error_msg = "rte_lw: inc_flux has values < 0"
    end if
    if(len_trim(error_msg) > 0) return

    !
    ! Number of quadrature points for no-scattering calculation
    !
    n_quad_angs = 1
    if(present(n_gauss_angles)) then
      if(n_gauss_angles > max_gauss_pts) &
        error_msg = "rte_lw: asking for too many quadrature points for no-scattering calculation"
      if(n_gauss_angles < 1) &
        error_msg = "rte_lw: have to ask for at least one quadrature point for no-scattering calculation"
      n_quad_angs = n_gauss_angles
    end if
    !
    ! Ensure values of tau, ssa, and g are reasonable
    !
    error_msg =  optical_props%validate()
    if(len_trim(error_msg) > 0) then
      if(len_trim(optical_props%get_name()) > 0) &
        error_msg = trim(optical_props%get_name()) // ': ' // trim(error_msg)
      return
    end if

    ! ------------------------------------------------------------------------------------
    !
    !    Lower boundary condition -- expand surface emissivity by band to gpoints
    !
    allocate(gpt_flux_up (ncol, nlay+1, ngpt), gpt_flux_dn(ncol, nlay+1, ngpt))
    allocate(sfc_emis_gpt(ncol,         ngpt))
    !$acc enter data copyin(sources%lay_source, sources%lev_source_inc, sources%lev_source_dec, sources%sfc_source)
    !$acc enter data copyin(gauss_Ds, gauss_wts)
    !$acc enter data create(gpt_flux_dn, gpt_flux_up)
    !$acc enter data create(sfc_emis_gpt)
    call expand_and_transpose(optical_props, sfc_emis, sfc_emis_gpt)
    !
    !   Upper boundary condition
    !
    if(present(inc_flux)) then
      !$acc enter data copyin(inc_flux)
      call apply_BC(ncol, nlay, ngpt, logical(top_at_1, wl), inc_flux, gpt_flux_dn)
      !$acc exit data delete(inc_flux)
    else
      !
      ! Default is zero incident diffuse flux
      !
      call apply_BC(ncol, nlay, ngpt, logical(top_at_1, wl),           gpt_flux_dn)
    end if

    !
    ! Compute the radiative transfer...
    !
    select type (optical_props)
      class is (ty_optical_props_1scl)
        !
        ! No scattering two-stream calculation
        !
        !$acc enter data copyin(optical_props%tau)
        call lw_solver_noscat_GaussQuad(ncol, nlay, ngpt, logical(top_at_1, wl), &
                              n_quad_angs, gauss_Ds(1:n_quad_angs,n_quad_angs), gauss_wts(1:n_quad_angs,n_quad_angs), &
                              optical_props%tau,                                                  &
                              sources%lay_source, sources%lev_source_inc, sources%lev_source_dec, &
                              sfc_emis_gpt, sources%sfc_source,  &
                              gpt_flux_up, gpt_flux_dn)
        !$acc exit data delete(optical_props%tau)
      class is (ty_optical_props_2str)
        !
        ! two-stream calculation with scattering
        !
        !$acc enter data copyin(optical_props%tau, optical_props%ssa, optical_props%g)
        call lw_solver_2stream(ncol, nlay, ngpt, logical(top_at_1, wl), &
                               optical_props%tau, optical_props%ssa, optical_props%g,              &
                               sources%lay_source, sources%lev_source_inc, sources%lev_source_dec, &
                               sfc_emis_gpt, sources%sfc_source,       &
                               gpt_flux_up, gpt_flux_dn)
        !$acc exit data delete(optical_props%tau, optical_props%ssa, optical_props%g)
      class is (ty_optical_props_nstr)
        !
        ! n-stream calculation
        !
        error_msg = 'lw_solver(...ty_optical_props_nstr...) not yet implemented'
    end select

    if (error_msg /= '') return
    !
    ! ...and reduce spectral fluxes to desired output quantities
    !
    error_msg = fluxes%reduce(gpt_flux_up, gpt_flux_dn, optical_props, top_at_1)
    !$acc exit data delete(sources%lay_source, sources%lev_source_inc, sources%lev_source_dec, sources%sfc_source)
    !$acc exit data delete(sfc_emis_gpt, gauss_Ds, gauss_wts)
    !$acc exit data delete(gpt_flux_up,gpt_flux_dn)
  end function rte_lw
  !--------------------------------------------------------------------------------------------------------------------
  !
  ! Expand from band to g-point dimension, transpose dimensions (nband, ncol) -> (ncol,ngpt)
  !
  subroutine expand_and_transpose(ops,arr_in,arr_out)
    class(ty_optical_props),  intent(in ) :: ops
    real(wp), dimension(:,:), intent(in ) :: arr_in  ! (nband, ncol)
    real(wp), dimension(:,:), intent(out) :: arr_out ! (ncol, igpt)
    ! -------------
    integer :: ncol, nband, ngpt
    integer :: icol, iband, igpt
    integer, dimension(2,ops%get_nband()) :: limits

    ncol  = size(arr_in, 2)
    nband = ops%get_nband()
    ngpt  = ops%get_ngpt()
    limits = ops%get_band_lims_gpoint()
    !$acc parallel loop collapse(2) copyin(arr_in, limits)
    do iband = 1, nband
      do icol = 1, ncol
        do igpt = limits(1, iband), limits(2, iband)
          arr_out(icol, igpt) = arr_in(iband,icol)
        end do
      end do
    end do

  end subroutine expand_and_transpose
  !--------------------------------------------------------------------------------------------------------------------
end module mo_rte_lw
