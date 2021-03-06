# FIXME - Enable multiple hostnames to be associated with the same site

# You'll need this if you are going to add regions into your extension interface.
require 'yaml'
require 'ostruct'
require_dependency 'application_controller'
require File.join(File.dirname(__FILE__), 'lib/scoped_access_init')
require File.join(File.dirname(__FILE__), 'vendor/scoped_access/lib/scoped_access')

class VhostExtension < Radiant::Extension
  version "2.0"
  description "Host multiple sites on a single instance."
  url "http://github.com/jgarber/radiant-vhost-extension"

  # FIXME - Clear up the configuration stuff, it's kinda crufty
  
  class << self
    # Set during tests and used to simulate having a populated request.host
    attr_accessor :HOST
    # Sets the models that are scoped down to a site
    attr_accessor :MODELS
    attr_accessor :MODEL_UNIQUENESS_VALIDATIONS
    attr_accessor :REDIRECT_TO_PRIMARY_SITE
  end

  # These routes are added to the radiant routes file and works just like any rails routes.
  define_routes do |map|
    map.namespace :admin, :member => { :remove => :get } do |admin|
      admin.resources :sites
    end
  end
  
  def activate
    process_config
    basic_extension_config
    init_scoped_access
    enable_caching
    modify_classes
    extension_support
  end
  
  def deactivate
    admin.tabs.remove "Sites"
  end

  def self.read_config
    # Enable quick SiteScoping of other Models via vhost.yml config file
    default_config = YAML.load(ERB.new(File.read(File.dirname(__FILE__) + '/lib/vhost_default_config.yml')).result).symbolize_keys
    begin
      custom_config = YAML.load(ERB.new(File.read(RAILS_ROOT + '/config/vhost.yml')).result).symbolize_keys rescue nil
      default_config[:models].merge!(custom_config[:models]) unless custom_config[:models].nil?
      default_config[:redirect_to_primary_site] = custom_config[:redirect_to_primary_site] unless custom_config[:redirect_to_primary_site].nil?
    rescue
    end
    config = {}
    config[:redirect_to_primary_site] = default_config[:redirect_to_primary_site]
    config[:models] = default_config[:models].collect{|key,val| key.to_s}
    config[:model_uniqueness_validations] = default_config[:models]
    config
  end
  
  private

  def basic_extension_config
    admin.tabs.add "Sites", "/admin/sites", :after => "Layouts", :visibility => [:admin]
    admin.user.edit.form.delete 'edit_roles'
    admin.user.edit.add :form, 'admin/users/edit_roles', :after => 'edit_password'
    admin.user.edit.add :form, 'admin/users/edit_sites', :after => 'edit_roles'

    # This adds information to the Radiant interface. In this extension, we're dealing with "site" views
    # so :sites is an attr_accessor. If you're creating an extension for tracking moons and stars, you might
    # put attr_accessor :moon, :star
    Radiant::AdminUI.class_eval do
      attr_accessor :sites
    end
    # initialize regions for help (which we created above)
    admin.sites = load_default_site_regions
  end
  
  def process_config
    config = VhostExtension.read_config
    
    VhostExtension.REDIRECT_TO_PRIMARY_SITE = config[:redirect_to_primary_site]
    
    # Set the MODELS and MODEL_VALIDATIONS class variables so everything else can access it
    VhostExtension.MODELS = config[:models]
    VhostExtension.MODEL_UNIQUENESS_VALIDATIONS = config[:model_uniqueness_validations]
  end
  
  def init_scoped_access
    # Configure the ScopedAccess stuff to scope models to Sites
    # Unfortunately adding the filters to the ApplicationController isn't enough
    # they need to also be added to all of the subclasses (which, surprisingly
    # only shows as the Admin::PagesController and Admin::ResourceController)
    controllers = ['ApplicationController']
    controllers.concat ApplicationController.subclasses
    controllers.each do |controller| controller.constantize.send :include, SiteScope end
  
    VhostExtension.MODELS.each do |model|
      # Instantiate the ScopedAccess filter for each model
      controllers.each do |controller| controller.constantize.send :prepend_around_filter, ScopedAccess::Filter.new(model.constantize, :site_scope) end
      # Enable class level calls like 'Layout.class.current_site' for each model (overkill?)
      model.constantize.send :cattr_accessor, :current_site
      model.constantize.send :include, Vhost::SiteScopedModelExtensions
    end
    # Enable instance level calls like 'my_layout.current_site' for each model (overkill?)
    controllers.each do |controller| controller.constantize.send :before_filter, :set_site_scope_in_models end

    # Wrap UsersController with site scoping for Site Admins
    Admin::UsersController.send :prepend_around_filter, ScopedAccess::Filter.new(User, :users_site_scope)
  end
  
  def enable_caching
    # Enable caching per site
    Radiant::Cache.send :include, Vhost::RadiantCacheExtensions::RadiantCache
    Radiant::Cache::MetaStore.send :include, Vhost::RadiantCacheExtensions::MetaStore
    Admin::PagesController.send :include, Vhost::PagesControllerExtensions
  end
  
  def modify_classes
    # Send all of the Vhost extensions and class modifications 
    User.send :has_and_belongs_to_many, :sites
    ApplicationHelper.send :include, Vhost::ApplicationHelperExtensions
    Admin::UsersHelper.send :include, Vhost::AdminUsersHelperExtensions
    Admin::UsersController.send :include, Vhost::AdminUsersControllerExtensions
    # Prevents a user from Site A logging into Site B's admin area (need a spec
    # for this to ensure it's working)
    Admin::ResourceController.send :include, Vhost::ControllerAccessExtensions
    Admin::PagesController.send :include, Vhost::ControllerAccessExtensions 
    ApplicationController.send :include, Vhost::ApplicationControllerExtensions 
  end
  
  def extension_support
    # SUPPORT FOR OTHER EXTENSIONS
    # I'm sure there's an DRYer way to do these checks, doing it the poor way for now.
    
    # FCKeditor
    fck = Kernel.const_get("FckeditorExtension") rescue false
    if fck
      # FIXME - use class_eval to rewrite methods instead of removing methods
      # here and adding them in the extension.
      FckeditorController.send :remove_method, :current_directory_path
      FckeditorController.send :remove_method, :upload_directory_path
      FckeditorController.send :include, Vhost::FckeditorExtensions::Controller
    end

    # File Manager
    mf = Kernel.const_get("ManagedFile") rescue false
    if mf
      ManagedFile.send :include, Vhost::ManagedFileExtensions
    end

    # Gallery
    gl = Kernel.const_get("Gallery") rescue false
    if gl
      GalleryItem.send :include, Vhost::GalleryItemExtensions
    end

    # Podcast
    mf = Kernel.const_get("PodcastImage") rescue false
    if mf
      PodcastImage.send :include, Vhost::PodcastImageExtensions
      PodcastEpisode.send :include, Vhost::PodcastEpisodeExtensions
    end

  end

  # Defines this extension's default regions (so that we can incorporate shards
  # into its views).
  def load_default_site_regions
    returning OpenStruct.new do |site|
      site.edit = Radiant::AdminUI::RegionSet.new do |edit|
        edit.main.concat %w{edit_header edit_form}
        edit.form.concat %w{edit_hostname edit_users}
        edit.form_bottom.concat %w{edit_buttons}
      end
      site.new = Radiant::AdminUI::RegionSet.new do |new|
        new.main.concat %w{edit_header edit_form}
        new.form.concat %w{edit_hostname edit_users}
        new.form_bottom.concat %w{edit_buttons}
      end
    end
  end
  
end
