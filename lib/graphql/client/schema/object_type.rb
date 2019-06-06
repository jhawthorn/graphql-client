# frozen_string_literal: true
require "active_support/inflector"
require "graphql/client/error"
require "graphql/client/errors"
require "graphql/client/schema/base_type"
require "graphql/client/schema/possible_types"

module GraphQL
  class Client
    module Schema
      module ObjectType
        def self.new(type, fields = {})
          Class.new(ObjectClass) do
            extend BaseType
            extend ObjectType

            define_singleton_method(:type) { type }
            define_singleton_method(:fields) { fields }

            const_set(:FIELDS, {})
            define_fields(base_fields)
          end
        end

        def base_fields
          type.all_fields.map(&:name).map(&:to_sym) | [:__typename]
        end

        def define_class(definition, ast_nodes)
          # First, gather all the ast nodes representing a certain selection, by name.
          # We gather AST nodes into arrays so that multiple selections can be grouped, for example:
          #
          #   {
          #     f1 { a b }
          #     f1 { b c }
          #   }
          #
          # should be treated like `f1 { a b c }`
          field_nodes = {}
          ast_nodes.each do |ast_node|
            ast_node.selections.each do |selected_ast_node|
              gather_selections(field_nodes, definition, selected_ast_node)
            end
          end

          # After gathering all the nodes by name, prepare to create methods and classes for them.
          field_classes = {}
          field_nodes.each do |result_name, field_ast_nodes|
            # `result_name` might be an alias, so make sure to get the proper name
            field_name = field_ast_nodes.first.name
            field_definition = definition.client.schema.get_field(type.name, field_name)
            field_return_type = field_definition.type
            field_classes[result_name.to_sym] = schema_module.define_class(definition, field_ast_nodes, field_return_type)
          end

          klass = Class.new(self)
          klass.const_set :FIELDS, FIELDS_CACHE[field_classes]

          extra_attributes = field_classes.keys - base_fields
          klass.define_fields(extra_attributes) if extra_attributes.any?

          klass.instance_variable_set(:@source_definition, definition)
          klass.instance_variable_set(:@_spreads, definition.indexes[:spreads][ast_nodes.first])

          if definition.client.enforce_collocated_callers
            keys = field_classes.keys.map { |key| ActiveSupport::Inflector.underscore(key) }
            Client.enforce_collocated_callers(klass, keys, definition.source_location[0])
          end

          klass
        end

        PREDICATE_CACHE = Hash.new { |h, key|
          h[key] = -> {
            name = key.to_s
            if self.class::FIELDS.key?(key)
              @data[name] ? true : false
            else
              error_on_defined_field(name)
            end
          }
        }

        METHOD_CACHE = Hash.new { |h, key|
          h[key] = -> {
            name = key.to_s
            type = self.class::FIELDS[key]
            if type
              @casted_data.fetch(name) do
                @casted_data[name] = type.cast(@data[name], @errors.filter_by_path(name))
              end
            else
              error_on_defined_field(name)
            end
          }
        }

        MODULE_CACHE = Hash.new do |h, fields|
          h[fields] = Module.new do
            fields.each do |name|
              GraphQL::Client::Schema::ObjectType.define_cached_field(name, self)
            end
          end
        end

        FIELDS_CACHE = Hash.new { |h, k| h[k] = k }

        def define_fields(fields)
          mod = MODULE_CACHE[fields.sort]
          include mod
        end

        def self.define_cached_field(name, ctx)
          key = name
          name = -name.to_s
          method_name = ActiveSupport::Inflector.underscore(name)

          ctx.send(:define_method, method_name, &METHOD_CACHE[key])
          ctx.send(:define_method, "#{method_name}?", &PREDICATE_CACHE[key])
        end

        def define_field(name, type)
          name = name.to_s
          method_name = ActiveSupport::Inflector.underscore(name)

          define_method(method_name) do
            @casted_data.fetch(name) do
              @casted_data[name] = type.cast(@data[name], @errors.filter_by_path(name))
            end
          end

          define_method("#{method_name}?") do
            @data[name] ? true : false
          end
        end

        def cast(value, errors)
          case value
          when Hash
            new(value, errors)
          when NilClass
            nil
          else
            raise InvariantError, "expected value to be a Hash, but was #{value.class}"
          end
        end

        private

        # Given an AST selection on this object, gather it into `fields` if it applies.
        # If it's a fragment, continue recursively checking the selections on the fragment.
        def gather_selections(fields, definition, selected_ast_node)
          case selected_ast_node
          when GraphQL::Language::Nodes::InlineFragment
            continue_selection = if selected_ast_node.type.nil?
              true
            else
              schema = definition.client.schema
              type_condition = schema.types[selected_ast_node.type.name]
              applicable_types = schema.possible_types(type_condition)
              # continue if this object type is one of the types matching the fragment condition
              applicable_types.include?(type)
            end

            if continue_selection
              selected_ast_node.selections.each do |next_selected_ast_node|
                gather_selections(fields, definition, next_selected_ast_node)
              end
            end
          when GraphQL::Language::Nodes::FragmentSpread
            fragment_definition = definition.document.definitions.find do |defn|
              defn.is_a?(GraphQL::Language::Nodes::FragmentDefinition) && defn.name == selected_ast_node.name
            end

            schema = definition.client.schema
            type_condition = schema.types[fragment_definition.type.name]
            applicable_types = schema.possible_types(type_condition)
            # continue if this object type is one of the types matching the fragment condition
            continue_selection = applicable_types.include?(type)

            if continue_selection
              fragment_definition.selections.each do |next_selected_ast_node|
                gather_selections(fields, definition, next_selected_ast_node)
              end
            end
          when GraphQL::Language::Nodes::Field
            operation_definition_for_field = definition.indexes[:definitions][selected_ast_node]
            # Ignore fields defined in other documents.
            if definition.source_document.definitions.include?(operation_definition_for_field)
              field_method_name = selected_ast_node.alias || selected_ast_node.name
              ast_nodes = fields[field_method_name] ||= []
              ast_nodes << selected_ast_node
            end
          else
            raise "Unexpected selection node: #{selected_ast_node}"
          end
        end
      end

      class ObjectClass
        module ClassMethods
          attr_reader :source_definition
          attr_reader :_spreads
        end

        extend ClassMethods

        def initialize(data = {}, errors = Errors.new)
          @data = data
          @casted_data = {}
          @errors = errors
        end

        # Public: Returns the raw response data
        #
        # Returns Hash
        def to_h
          @data
        end

        # Public: Return errors associated with data.
        #
        # Returns Errors collection.
        attr_reader :errors

        def method_missing(*args)
          super
        rescue NoMethodError => e
          type = self.class.type

          if ActiveSupport::Inflector.underscore(e.name.to_s) != e.name.to_s
            raise e
          end

          raise UnimplementedFieldError, "undefined field `#{e.name}' on #{type} type. https://git.io/v1y3m"
        end

        def inspect
          parent = self.class.ancestors.select { |m| m.is_a?(ObjectType) }.last

          ivars = @data.map { |key, value|
            if value.is_a?(Hash) || value.is_a?(Array)
              "#{key}=..."
            else
              "#{key}=#{value.inspect}"
            end
          }

          buf = "#<#{parent.name}".dup
          buf << " " << ivars.join(" ") if ivars.any?
          buf << ">"
          buf
        end

        private

        def error_on_defined_field(name)
          type = self.class.type
          if @data.key?(name)
            raise ImplicitlyFetchedFieldError,
              "implicitly fetched field `#{name}' on #{type} type. https://git.io/v1yGL"
          else
            raise UnfetchedFieldError,
              "unfetched field `#{name}' on #{type} type. https://git.io/v1y3U"
          end
        end
      end
    end
  end
end
