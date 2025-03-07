class RegistrationsController < Devise::RegistrationsController
  prepend_before_action :require_no_authentication, only: []

  def new
    return redirect_to root_path(signin: "true") if user_signed_in?

    if URI(request.referer || "").host == URI(request.base_url).host
      store_location_for(:user, request.referer)
    end

    super
  end

  def create
    authorize(params, policy_class: RegistrationPolicy)

    resolve_profile_field_issues

    unless recaptcha_verified?
      flash[:notice] = "You must complete the recaptcha ✅"
      return redirect_to new_user_registration_path(state: "email_signup")
    end

    build_devise_resource

    if resource.persisted?
      update_first_user_permissions(resource)

      if ForemInstance.smtp_enabled?
        redirect_to confirm_email_path(email: resource.email)
      else
        sign_in(resource)
        redirect_to root_path
      end
    else
      render action: "by_email"
    end
  end

  private

  def update_first_user_permissions(resource)
    return unless Settings::General.waiting_on_first_user

    resource.add_role(:super_admin)
    resource.add_role(:trusted)
    resource.skip_confirmation!
    Settings::General.waiting_on_first_user = false
    Users::CreateMascotAccount.call
  end

  def recaptcha_verified?
    if ReCaptcha::CheckRegistrationEnabled.call
      recaptcha_params = { secret_key: Settings::Authentication.recaptcha_secret_key }
      params["g-recaptcha-response"] && verify_recaptcha(recaptcha_params)
    else
      true
    end
  end

  def resolve_profile_field_issues
    # Run this data update script when in a state of "first user" in the event
    # that we are in a state where this was not already run.
    # This is likely only temporarily needed.
    return unless Settings::General.waiting_on_first_user

    csv = Rails.root.join("lib/data/dev_profile_fields.csv")
    ProfileFields::ImportFromCsv.call(csv)
  end

  def check_allowed_email(resource)
    domain = resource.email.split("@").last
    allow_list = Settings::Authentication.allowed_registration_email_domains
    return if allow_list.empty? || allow_list.include?(domain)

    resource.email = nil
    resource.errors.add(:email, "is not included in allowed domains.")
  end

  def build_devise_resource
    build_resource(sign_up_params)
    resource.registered_at = Time.current
    resource.remote_profile_image_url = Users::ProfileImageGenerator.call if resource.remote_profile_image_url.blank?
    check_allowed_email(resource) if resource.email.present?
    resource.save if resource.email.present?
  end
end
