module Chewy
  class Index
    # Module provides per-index actions, such as deletion,
    # creation and existance check.
    #
    module Actions
      extend ActiveSupport::Concern

      module ClassMethods
        # Checks index existance. Returns true or false
        #
        #   UsersIndex.exist? #=> true
        #
        def exists?
          client.indices.exists(index: index_name)
        end

        # Creates index and applies mappings and settings.
        # Returns false in case of unsuccessful creation.
        #
        #   UsersIndex.create # creates index named `users`
        #
        # Index name suffix might be passed optionally. In this case,
        # method creates index with suffix and makes unsuffixed alias
        # for it.
        #
        #   UsersIndex.create '01-2013' # creates index `uses_01-2013` and alias `users` for it
        #   UsersIndex.create '01-2013', alias: false # creates index `uses_01-2013` only and no alias
        #
        # Suffixed index names might be used for zero-downtime mapping change, for example.
        # Description: (http://www.elasticsearch.org/blog/changing-mapping-with-zero-downtime/).
        #
        def create *args
          create! *args
        rescue Elasticsearch::Transport::Transport::Errors::BadRequest
          false
        end

        # Creates index and applies mappings and settings.
        # Raises elasticsearch-ruby transport error in case of
        # unsuccessfull creation.
        #
        #   UsersIndex.create! # creates index named `users`
        #
        # Index name suffix might be passed optionally. In this case,
        # method creates index with suffix and makes unsuffixed alias
        # for it.
        #
        #   UsersIndex.create! '01-2014' # creates index `users_01-2014` and alias `users` for it
        #   UsersIndex.create! '01-2014', alias: false # creates index `users_01-2014` only and no alias
        #
        # Suffixed index names might be used for zero-downtime mapping change, for example.
        # Description: (http://www.elasticsearch.org/blog/changing-mapping-with-zero-downtime/).
        #
        def create! *args
          options = args.extract_options!.reverse_merge!(alias: true)
          name = build_index_name(suffix: args.first)

          Chewy.wait_for_status

          result = client.indices.create(index: name, body: index_params)
          result &&= client.indices.put_alias(index: name, name: index_name) if options[:alias] && name != index_name
          result
        end

        # Deletes ES index. Returns false in case of error.
        #
        #   UsersIndex.delete # deletes `users` index
        #
        # Supports index suffix passed as the first argument
        #
        #   UsersIndex.delete '01-2014' # deletes `users_01-2014` index
        #
        def delete suffix = nil
          delete! suffix
        rescue Elasticsearch::Transport::Transport::Errors::NotFound
          false
        end

        # Deletes ES index. Raises elasticsearch-ruby transport error
        # in case of error.
        #
        #   UsersIndex.delete # deletes `users` index
        #
        # Supports index suffix passed as the first argument
        #
        #   UsersIndex.delete '01-2014' # deletes `users_01-2014` index
        #
        def delete! suffix = nil
          Chewy.wait_for_status

          client.indices.delete index: build_index_name(suffix: suffix)
        end

        # Deletes and recreates index. Supports suffixes.
        # Returns result of index creation.
        #
        #   UsersIndex.purge # deletes and creates `users` index
        #   UsersIndex.purge '01-2014' # deletes `users` and `users_01-2014` indexes, creates `users_01-2014`
        #
        def purge suffix = nil
          delete if suffix.present?
          delete suffix
          create suffix
        end

        # Deletes and recreates index. Supports suffixes.
        # Returns result of index creation. Raises error in case
        # of unsuccessfull creation
        #
        #   UsersIndex.purge! # deletes and creates `users` index
        #   UsersIndex.purge! '01-2014' # deletes `users` and `users_01-2014` indexes, creates `users_01-2014`
        #
        def purge! suffix = nil
          begin
            delete! if suffix.present? && exists?
            delete! suffix
          rescue Elasticsearch::Transport::Transport::Errors::NotFound
          end
          create! suffix
        end

        # Perform import operation for every defined type
        #
        #   UsersIndex.import                           # imports default data for every index type
        #   UsersIndex.import user: User.active         # imports specified objects for user type and default data for other types
        #   UsersIndex.import refresh: false            # to disable index refreshing after import
        #   UsersIndex.import suffix: Time.now.to_i     # imports data to index with specified suffix if such is exists
        #   UsersIndex.import batch_size: 300           # import batch size
        #
        [:import, :import!].each do |method|
          class_eval <<-METHOD, __FILE__, __LINE__ + 1
            def #{method} options = {}
              objects = options.reject { |k, v| !type_names.map(&:to_sym).include?(k) }
              types.map do |type|
                args = [objects[type.type_name.to_sym], options.dup].reject(&:blank?)
                type.#{method} *args
              end.all?
            end
          METHOD
        end

        # Deletes, creates and imports data to the index.
        # Returns import result
        #
        #   UsersIndex.reset!
        #
        # If index name suffix passed as the first argument - performs
        # zero-downtime index resetting (described here:
        # http://www.elasticsearch.org/blog/changing-mapping-with-zero-downtime/).
        #
        #   UsersIndex.reset! Time.now.to_i
        #
        def reset! suffix = nil
          if suffix.present? && (indexes = self.indexes).any?
            create! suffix, alias: false
            result = import suffix: suffix
            client.indices.update_aliases body: {actions: [
              *indexes.map do |index|
                {remove: {index: index, alias: index_name}}
              end,
              {add: {index: build_index_name(suffix: suffix), alias: index_name}}
            ]}
            client.indices.delete index: indexes if indexes.any?
            result
          else
            purge! suffix
            import
          end
        end
      end
    end
  end
end
