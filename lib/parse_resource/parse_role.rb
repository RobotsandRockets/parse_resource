class ParseRole < ParseResource::Base
  fields :name, :users, :roles

  def users
    User.related_to(self, :users)
  end

  def access_control
    get_attribute("ACL")
  end

  def self.create(attributes)
    base_uri   = "#{settings['api_url']}/roles"
    resource = RestClient::Resource.new(base_uri, headers: self.request_headers)
    data = {"name" => attributes[:name],
            "ACL" => {
              "*" => {
                "read" => attributes[:ACL][:read] ? attributes[:ACL][:read] : false,
                "write" => attributes[:ACL][:write] ? attributes[:ACL][:write] : false}}}
    json_data = data.to_json
    begin
      resp = resource.post json_data, :content_type => "application/json"
      role = Role.find(JSON.parse(resp)["objectId"])
    rescue
      false
    end    
  end

  def add_user(user)
    # Expects user parameter to be a ParseUser object
    base_uri   = "#{self.class.settings['api_url']}/roles/#{self.objectId}"
    resource = RestClient::Resource.new(base_uri, headers: self.request_headers)
    data = {"users" => {"__op" => "AddRelation", 
                        "objects" => [{"__type" => "Pointer", 
                                       "className" => "_User", 
                                       "objectId" => user.objectId}] } }
    json_data = data.to_json
    begin
      resp = resource.put json_data, :content_type => "application/json"
    rescue
      false
    end
  end

  def remove_user(user)
    # Expects user parameter to be a ParseUser object
    
    base_uri   = "#{self.class.settings['api_url']}/roles/#{self.objectId}"
    resource = RestClient::Resource.new(base_uri, headers: self.request_headers)
    data = {"users" => {"__op" => "RemoveRelation", 
                        "objects" => [{"__type" => "Pointer", 
                                       "className" => "_User", 
                                       "objectId" => user.objectId}] } }
    json_data = data.to_json
    begin
      resp = resource.put json_data, :content_type => "application/json"
    rescue
      false
    end
  end

end
