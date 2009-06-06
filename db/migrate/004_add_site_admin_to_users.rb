class AddSiteAdminToUsers < ActiveRecord::Migration
  def self.up
    add_column :users, :site_admin, :boolean
  end

  def self.down
    remove_column :users, :site_admin
  end
end
