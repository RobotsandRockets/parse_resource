require "rubygems"
require "bundler/setup"
require "active_model"
require "erb"
require "rest-client"
require "json"
require "active_support/hash_with_indifferent_access"
require "parse_resource/query"
require "parse_resource/query_methods"
require "parse_resource/parse_error"
require "parse_resource/parse_exceptions"
require "parse_resource/types/parse_geopoint"
require "parse_resource/relation_array"

module ParseResource


  class Base
    # ParseResource::Base provides an easy way to use Ruby to interace with a Parse.com backend
    # Usage:
    #  class Post < ParseResource::Base
    #    fields :title, :author, :body
    #  end

    @@has_many_relations = []
    @@belongs_to_relations = []

    include ActiveModel::Validations
    include ActiveModel::Validations::Callbacks
    include ActiveModel::Conversion
    include ActiveModel::AttributeMethods
    extend ActiveModel::Naming
    extend ActiveModel::Callbacks
    HashWithIndifferentAccess = ActiveSupport::HashWithIndifferentAccess

    attr_accessor :error_instances

    define_model_callbacks :save, :create, :update, :destroy

    # Instantiates a ParseResource::Base object
    #
    # @params [Hash], [Boolean] a `Hash` of attributes and a `Boolean` that should be false only if the object already exists
    # @return [ParseResource::Base] an object that subclasses `Parseresource::Base`
    def initialize(attributes = {}, new=true)
      #attributes = HashWithIndifferentAccess.new(attributes)

      if new
        @unsaved_attributes = attributes
        @unsaved_attributes.stringify_keys!
      else
        @unsaved_attributes = {}
      end
      @attributes = {}
      self.error_instances = []

      self.attributes.merge!(attributes)
      self.attributes unless self.attributes.empty?
      create_setters_and_getters!
    end

    # Explicitly adds a field to the model.
    #
    # @param [Symbol] name the name of the field, eg `:author`.
    # @param [Boolean] val the return value of the field. Only use this within the class.
    def self.field(fname, val=nil)
      fname = fname.to_sym
      class_eval do
        define_method(fname) do
          get_attribute("#{fname}")
        end
      end
      unless self.respond_to? "#{fname}="
        class_eval do
          define_method("#{fname}=") do |val|
            set_attribute("#{fname}", val)

            val
          end
        end
      end
    end

    # Add multiple fields in one line. Same as `#field`, but accepts multiple args.
    #
    # @param [Array] *args an array of `Symbol`s, `eg :author, :body, :title`.
    def self.fields(*args)
      args.each {|f| field(f)}
    end

    # Similar to its ActiveRecord counterpart.
    #
    # @param [Hash] options Added so that you can specify :class_name => '...'. It does nothing at all, but helps you write self-documenting code.
    def self.belongs_to(parent, options = {})
      field(parent)
      @@belongs_to_relations << parent
    end

    # Creates setter and getter in order access the specified relation for this Model
    #
    # @param [Hash] options Added so that you can specify :class_name => '...'. It does nothing at all, but helps you write self-documenting code.
    def self.has_many(parent, options = {})
      field(parent)
      @@has_many_relations << parent
    end

    def to_pointer
      klass_name = self.class.model_name.to_s
      klass_name = "_User" if klass_name == "User"
      klass_name = "_Installation" if klass_name == "Installation"
      klass_name = "_Role" if klass_name == "Role"
      klass_name = "_Session" if klass_name == "Session"
      {"__type" => "Pointer", "className" => klass_name.to_s, "objectId" => self.id}
    end

    def self.to_date_object(date)
      date = date.to_time if date.respond_to?(:to_time)
      {"__type" => "Date", "iso" => date.getutc.iso8601} if date && (date.is_a?(Date) || date.is_a?(DateTime) || date.is_a?(Time))
    end

    # Creates setter methods for model fields
    def create_setters!(k,v)
      unless self.respond_to? "#{k}="
        self.class.send(:define_method, "#{k}=") do |val|
          set_attribute("#{k}", val)

          val
        end
      end
    end

    def self.method_missing(method_name, *args)
      method_name = method_name.to_s
      if method_name.start_with?("find_by_")
        attrib   = method_name.gsub(/^find_by_/,"")
        finder_name = "find_all_by_#{attrib}"

        define_singleton_method(finder_name) do |target_value|
          where({attrib.to_sym => target_value}).first
        end

        send(finder_name, args[0])

      elsif method_name.start_with?("find_all_by_")
        attrib   = method_name.gsub(/^find_all_by_/,"")
        finder_name = "find_all_by_#{attrib}"

        define_singleton_method(finder_name) do |target_value|
          where({attrib.to_sym => target_value}).all
        end

        send(finder_name, args[0])
      else
        super(method_name.to_sym, *args)
      end
    end

    # Creates getter methods for model fields
    def create_getters!(k,v)
      unless self.respond_to? "#{k}"
        self.class.send(:define_method, "#{k}") do
          get_attribute("#{k}")
        end
      end
    end

    def create_setters_and_getters!
      @attributes.each_pair do |k,v|
        create_setters!(k,v)
        create_getters!(k,v)
      end
    end

    @@settings ||= nil

    # Explicitly set Parse.com API keys.
    #
    # @param [String] app_id the Application ID of your Parse database
    # @param [String] master_key the Master Key of your Parse database
    def self.load!(app_id, rest_api_key, master_key, api_url = 'https://api.parse.com/1', session_token = nil)
      @@settings = {"app_id" => app_id, "rest_api_key" => rest_api_key, "master_key" => master_key, "api_url" => api_url, "session_token" => session_token, "use_master_key" => false }
    end

    def self.session_token=(session_token)
      @@settings['session_token'] = session_token
    end

    def self.use_master_key!
      @@settings['use_master_key'] = true
    end

    def self.request_headers
      headers = {
        content_type: "application/json",
        x_parse_application_id: @@settings['app_id'],
        x_parse_rest_api_key: @@settings['rest_api_key'],
        x_parse_session_token: @@settings['session_token']
      }
      if @@settings['use_master_key']
        headers[:x_parse_master_key] = @@settings['master_key']
        headers.delete(:x_parse_session_token)
      end
      headers
    end

    def self.settings
      load_settings
    end

    # Gets the current class's model name for the URI
    def self.model_name_uri
      # This is a workaround to allow the user to specify a custom class
      if defined?(self.parse_class_name)
        "classes/#{self.parse_class_name}"
      elsif self.model_name.to_s == "User"
        "users"
      elsif self.model_name.to_s == "Installation"
        "installations"
      elsif self.model_name.to_s == "Role"
        "roles"
      elsif self.model_name.to_s == "Session"
        "sessions"
      else
        "classes/#{self.model_name.to_s}"
      end
    end

    # Gets the current class's Parse.com base_uri
    def self.model_base_uri
      "#{@@settings['api_url']}/#{model_name_uri}"
    end

    # Gets the current instance's parent class's Parse.com base_uri
    def model_base_uri
      self.class.send(:model_base_uri)
    end


    # Creates a RESTful resource
    # sends requests to [base_uri]/[classname]
    #
    def self.resource
      load_settings
      RestClient::Resource.new(self.model_base_uri, headers: self.request_headers)
    end

    # Batch requests
    # Sends multiple requests to /batch
    # Set slice_size to send larger batches. Defaults to 20 to prevent timeouts.
    # Parse doesn't support batches of over 20.
    #
    def self.batch_save(save_objects, slice_size = 20, method = nil)
      return true if save_objects.blank?
      load_settings

      base_path = File.basename(@@settings['api_url'])
      base_uri = "#{@@settings['api_url']}/batch"

      res = RestClient::Resource.new(base_uri, headers: self.request_headers)

      # Batch saves seem to fail if they're too big. We'll slice it up into multiple posts if they are.
      save_objects.each_slice(slice_size) do |objects|
        # attributes_for_saving
        batch_json = { "requests" => [] }

        objects.each do |item|
          method ||= (item.new?) ? "POST" : "PUT"
          object_path =
            if base_path =~ /back4app/
              "/#{item.class.model_name_uri}"
            else
              "/#{base_path}/#{item.class.model_name_uri}"
            end
          object_path = "#{object_path}/#{item.id}" if item.id
          json = {
            "method" => method,
            "path" => object_path
          }
          json["body"] = item.attributes_for_saving unless method == "DELETE"
          batch_json["requests"] << json
        end
        res.post(batch_json.to_json, :content_type => "application/json") do |resp, req, res, &block|
          response = JSON.parse(resp) rescue nil
          if resp.code == 400
            return false
          end
          if response && response.is_a?(Array) && response.length == objects.length
            merge_all_attributes(objects, response) unless method == "DELETE"
          end
        end
      end
      true
    end

    def self.merge_all_attributes(objects, response)
      i = 0
      objects.each do |item|
        item.merge_attributes(response[i]["success"]) if response[i] && response[i]["success"]
        i += 1
      end
      nil
    end

    def self.save_all(objects)
      batch_save(objects)
    end

    def self.destroy_all(objects=nil)
      objects ||= self.all
      batch_save(objects, 20, "DELETE")
    end

    def self.delete_all(o)
      raise StandardError.new("Parse Resource: delete_all doesn't exist. Did you mean destroy_all?")
    end

    def self.load_settings
      @@settings ||= begin
        path = "config/parse_resource.yml"
        environment = defined?(Rails) && Rails.respond_to?(:env) ? Rails.env : ENV["RACK_ENV"]
        if FileTest.exist? (path)
          YAML.load(ERB.new(File.new(path).read).result)[environment]
        elsif ENV["PARSE_RESOURCE_APPLICATION_ID"] && ENV["PARSE_RESOURCE_MASTER_KEY"]
          settings = HashWithIndifferentAccess.new
          settings['app_id'] = ENV["PARSE_RESOURCE_APPLICATION_ID"]
          settings['master_key'] = ENV["PARSE_RESOURCE_MASTER_KEY"]
          settings
        else
          raise "Cannot load parse_resource.yml and API keys are not set in environment"
        end
      end
      @@settings
    end


    # Creates a RESTful resource for file uploads
    # sends requests to [base_uri]/files
    #
    def self.upload(file_instance, filename, options={})
      load_settings

      base_uri = "#{@@settings['api_url']}/files"

      options[:content_type] ||= 'image/jpg' # TODO: Guess mime type here.
      file_instance = File.new(file_instance, 'rb') if file_instance.is_a? String

      filename = filename.parameterize

      private_resource = RestClient::Resource.new "#{base_uri}/#{filename}", headers: self.request_headers
      private_resource.post(file_instance, options) do |resp, req, res, &block|
        return false if resp.code == 400
        return JSON.parse(resp) rescue {"code" => 0, "error" => "unknown error"}
      end
      false
    end

    # Find a ParseResource::Base object by ID
    #
    # @param [String] id the ID of the Parse object you want to find.
    # @return [ParseResource] an object that subclasses ParseResource.
    def self.find(id)
      raise RecordNotFound, "Couldn't find #{name} without an ID" if id.blank?
      record = where(:objectId => id).first
      raise RecordNotFound, "Couldn't find #{name} with id: #{id}" if record.blank?
      record
    end

    # Find a ParseResource::Base object by given key/value pair
    #
    def self.find_by(*args)
      raise RecordNotFound, "Couldn't find an object without arguments" if args.blank?
      key, value = args.first.first
      record = where(key => value).first
      record
    end

    # Find a ParseResource::Base object by chaining #where method calls.
    #
    def self.where(*args)
      Query.new(self).where(*args)
    end


    include ParseResource::QueryMethods


    def self.chunk(attribute)
      Query.new(self).chunk(attribute)
    end

    # Create a ParseResource::Base object.
    #
    # @param [Hash] attributes a `Hash` of attributes
    # @return [ParseResource] an object that subclasses `ParseResource`. Or returns `false` if object fails to save.
    def self.create(attributes = {})
      attributes = HashWithIndifferentAccess.new(attributes)
      obj = new(attributes)
      obj.save
      obj
    end

    # Replaced with a batch destroy_all method.
    # def self.destroy_all(all)
    #   all.each do |object|
    #     object.destroy
    #   end
    # end

    def self.class_attributes
      @class_attributes ||= {}
    end

    def persisted?
      if id
        true
      else
        false
      end
    end

    def new?
      !persisted?
    end

    # delegate from Class method
    def resource
      self.class.resource
    end

    # create RESTful resource for the specific Parse object
    # sends requests to [base_uri]/[classname]/[objectId]
    def instance_resource
      self.class.resource["#{self.id}"]
    end

    def pointerize(hash)
      new_hash = {}
      hash.each do |k, v|
        if v.respond_to?(:to_pointer)
          new_hash[k] = v.to_pointer
        elsif v.is_a?(Date) || v.is_a?(Time) || v.is_a?(DateTime)
          new_hash[k] = self.class.to_date_object(v)
        else
          new_hash[k] = v
        end
      end
      new_hash
    end

    def save
      if valid?
        run_callbacks :save do
          if new?
            create
          else
            update
          end
        end
      else
        false
      end
    rescue
      false
    end

    def create
      if valid?
        run_callbacks :create do
          attrs = attributes_for_saving.to_json
          opts = {:content_type => "application/json"}
          result = self.resource.post(attrs, opts) do |resp, req, res, &block|
            return post_result(resp, req, res, &block)
          end
        end
      else
        false
      end
    rescue
      false
    end

    def update(attributes = {})
      if valid?
        update_attributes(attributes)
      else
        false
      end
    rescue
      false
    end

    # Merges in the return value of a save and resets the unsaved_attributes
    def merge_attributes(results)
      @attributes.merge!(results)
      @attributes.merge!(@unsaved_attributes)

      merge_relations
      @unsaved_attributes = {}


      create_setters_and_getters!
      @attributes
    end

    def merge_relations
      # KK 11-17-2012 The response after creation does not return full description of
      # the object nor the relations it contains. Make another request here.
      if @@has_many_relations.map { |relation| relation.to_s.to_sym }
        #todo: make this a little smarter by checking if there are any Pointer objects in the objects attributes.
        @attributes = self.class.to_s.constantize.where(:objectId => @attributes["objectId"]).first.attributes
      end
    end

    def post_result(resp, req, res, &block)
      if resp.code.to_s == "200" || resp.code.to_s == "201"
        puts "request: #{req.inspect}"
        merge_attributes(JSON.parse(resp))

        return true
      else
        error_response = JSON.parse(resp)
        if error_response["error"]
          pe = ParseError.new(error_response["code"], error_response["error"])
        else
          pe = ParseError.new(resp.code.to_s)
        end
        self.errors.add(pe.code.to_s.to_sym, pe.msg)
        self.error_instances << pe
        return false
      end
    end

    def attributes_for_saving
      @unsaved_attributes = pointerize(@unsaved_attributes)
      put_attrs = @unsaved_attributes

      put_attrs = relations_for_saving(put_attrs)

      put_attrs.delete('objectId')
      put_attrs.delete('createdAt')
      put_attrs.delete('updatedAt')
      put_attrs
    end

    def relations_for_saving(put_attrs)
      all_add_item_queries = {}
      all_remove_item_queries = {}
      @unsaved_attributes.each_pair do |key, value|
        next if !value.is_a? Array

        # Go through the array in unsaved and check if they are in array in attributes (saved stuff)
        add_item_ops = []
        @unsaved_attributes[key].each do |item|
          found_item_in_saved = false
          @attributes[key].each do |item_in_saved|
            if !!(defined? item.attributes) && item.attributes["objectId"] == item_in_saved.attributes["objectId"]
              found_item_in_saved = true
            end
          end

          if !found_item_in_saved && !!(defined? item.objectId)
            # need to send additem operation to parse
            put_attrs.delete(key) # arrays should not be sent along with REST to parse api
            add_item_ops << {"__type" => "Pointer", "className" => item.class.to_s, "objectId" => item.objectId}
          end
        end
        all_add_item_queries.merge!({key => {"__op" => "Add", "objects" => add_item_ops}}) if !add_item_ops.empty?

        # Go through saved and if it isn't in unsaved perform a removeitem operation
        remove_item_ops = []
        unless @unsaved_attributes.empty?
          @attributes[key].each do |item|
            found_item_in_unsaved = false
            @unsaved_attributes[key].each do |item_in_unsaved|
              if !!(defined? item.attributes) && item.attributes["objectId"] == item_in_unsaved.attributes["objectId"]
                found_item_in_unsaved = true
              end
            end

            if !found_item_in_unsaved  && !!(defined? item.objectId)
              # need to send removeitem operation to parse
              remove_item_ops << {"__type" => "Pointer", "className" => item.class.to_s, "objectId" => item.objectId}
            end
          end
        end
        all_remove_item_queries.merge!({key => {"__op" => "Remove", "objects" => remove_item_ops}}) if !remove_item_ops.empty?
      end

      # TODO figure out a more elegant way to get this working. the remove_item merge overwrites the add.
      # Use a seperate query to add objects to the relation.
      #if !all_add_item_queries.empty?
      #  #result = self.instance_resource.put(all_add_item_queries.to_json, {:content_type => "application/json"}) do |resp, req, res, &block|
      #  #  return puts(resp, req, res, false, &block)
      #  #end
      #  puts result
      #end

      put_attrs.merge!(all_add_item_queries) unless all_add_item_queries.empty?
      put_attrs.merge!(all_remove_item_queries) unless all_remove_item_queries.empty?
      put_attrs
    end

    def update_attributes(attributes = {})
      attributes = HashWithIndifferentAccess.new(attributes)

      @unsaved_attributes.merge!(attributes)
      put_attrs = attributes_for_saving.to_json

      opts = {:content_type => "application/json"}
      result = self.instance_resource.put(put_attrs, opts) do |resp, req, res, &block|
        return post_result(resp, req, res, &block)
      end
    end

    def update_attribute(key, value)
      update_attributes({ key => value })
    end

    def destroy
      if self.instance_resource.delete
        @attributes = {}
        @unsaved_attributes = {}
        return true
      end
      false
    end

    def reload
      return false if new?

      fresh_object = self.class.find(id)
      @attributes.update(fresh_object.instance_variable_get('@attributes'))
      @unsaved_attributes = {}

      self
    end

    def dirty?
      @unsaved_attributes.length > 0
    end

    def clean?
      !dirty?
    end

    # provides access to @attributes for getting and setting
    def attributes
      @attributes ||= self.class.class_attributes
      @attributes
    end

    def attributes=(value)
      if value.is_a?(Hash) && value.present?
        value.each do |k, v|
          send "#{k}=", v
        end
      end
      @attributes
    end

    def get_attribute(k)
      attrs = @unsaved_attributes[k.to_s] ? @unsaved_attributes : @attributes
      case attrs[k]
      when Hash
        klass_name = attrs[k]["className"]
        klass_name = "User" if klass_name == "_User"
        case attrs[k]["__type"]
        when "Pointer"
          result = klass_name.to_s.constantize.find(attrs[k]["objectId"])
        when "Object"
          result = klass_name.to_s.constantize.new(attrs[k], false)
        when "Date"
          result = DateTime.parse(attrs[k]["iso"]).in_time_zone
        when "File"
          result = attrs[k]["url"]
        when "GeoPoint"
          result = ParseGeoPoint.new(attrs[k])
        when "Relation"
          objects_related_to_self = klass_name.constantize.where("$relatedTo" => {"object" => {"__type" => "Pointer", "className" => self.class.to_s, "objectId" => self.objectId}, "key" => k}).all
          attrs[k] = RelationArray.new self, objects_related_to_self, k, klass_name
          @unsaved_attributes[k] = RelationArray.new self, objects_related_to_self, k, klass_name
          result = @unsaved_attributes[k]
        else
          result = attrs[k]
        end #todo: support other types https://www.parse.com/docs/rest#objects-types
      else
        #relation will assign itself if an array, this will add to unsave_attributes
         if @@has_many_relations.index(k.to_s.to_sym)
          if attrs[k].nil?
            result = nil
          else
            @unsaved_attributes[k] = attrs[k].clone
            result = @unsaved_attributes[k]
          end
        else
          result =  attrs["#{k}"]
        end
      end
      result
    end

    def set_attribute(k, v)
      if v.is_a?(Date) || v.is_a?(Time) || v.is_a?(DateTime)
        v = self.class.to_date_object(v)
      elsif v.respond_to?(:to_pointer)
        v = v.to_pointer
      end
      @unsaved_attributes[k.to_s] = v unless v == @attributes[k.to_s] # || @unsaved_attributes[k.to_s]
      @attributes[k.to_s] = v
      v
    end

    def self.has_many_relations
      @@has_many_relations
    end

    def self.belongs_to_relations
      @@belongs_to_relations
    end


    # aliasing for idiomatic Ruby
    def id; get_attribute("objectId") rescue nil; end
    def objectId; get_attribute("objectId") rescue nil; end

    def created_at; get_attribute("createdAt"); end

    def updated_at; get_attribute("updatedAt"); rescue nil; end

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
    end

    #if we are comparing objects, use id if they are both ParseResource objects
    def ==(another_object)
      if another_object.class <= ParseResource::Base
        self.id == another_object.id
      else
        super
      end
    end

  end
end
