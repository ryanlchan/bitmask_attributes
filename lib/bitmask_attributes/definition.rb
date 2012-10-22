module BitmaskAttributes
  class Definition
    attr_reader :attribute, :values, :allow_null, :zero_value, :extension

    def initialize(attribute, values=[],allow_null = true,zero_value = nil, &extension)
      @attribute = attribute
      @values = values
      @extension = extension
      @allow_null = allow_null
      @zero_value = zero_value
    end

    def install_on(model)
      validate_for model
      generate_bitmasks_on model
      override model
      create_convenience_class_method_on model
      create_convenience_instance_methods_on model
      create_scopes_on model
      create_attribute_methods_on model
    end

    private

      def validate_for(model)
        # The model cannot be validated if it is preloaded and the attribute/column is not in the
        # database (the migration has not been run) or table doesn't exist. This usually
        # occurs in the 'test' and 'production' environment or during migration.
        return if defined?(Rails) && Rails.configuration.cache_classes || !model.table_exists?

        unless model.columns.detect { |col| col.name == attribute.to_s }
          missing_attribute(attribute, model)
        end
      end

      def missing_attribute(attribute, model)
        message = "WARNING: `#{attribute}' is not an attribute of `#{model.class.name}'. But, it's ok if it happens during migrations and your \"bitmasked\" attribute is still not created."
        if defined?(Rails)
          Rails.logger.warn message
        else
          STDERR.puts message
        end
      end

      def generate_bitmasks_on(model)
        model.bitmasks[attribute] = HashWithIndifferentAccess.new.tap do |mapping|
          values.each_with_index do |value, index|
            mapping[value] = 0b1 << index
          end
        end
      end

      def override(model)
        override_getter_on(model)
        override_setter_on(model)
      end

      def override_getter_on(model)
        model.class_eval %(
          def #{attribute}
            @#{attribute} ||= BitmaskAttributes::ValueProxy.new(self, :#{attribute}, &self.class.bitmask_definitions[:#{attribute}].extension)
          end
        )
      end

      def override_setter_on(model)
        model.class_eval %(
          def #{attribute}=(value)
            if value.is_a?(Fixnum)
              value = self.class.#{attribute}_for_bitmask(value)
            end
            values = value.kind_of?(Array) ? value : [value]
            self.#{attribute}.replace(values.reject{|value| #{eval_string_for_zero('value')}})
          end
        )
      end

      # Returns the defined values as an Array.
      def create_attribute_methods_on(model)
        model.class_eval %(
          def self.values_for_#{attribute}      # def self.values_for_numbers
            #{values}                           #   [:one, :two, :three]
          end                                   # end
        )
      end

      def create_convenience_class_method_on(model)
        model.class_eval %(
          def self.bitmask_for_#{attribute}(*values)
            values.inject(0) do |bitmask, value|
              if #{eval_string_for_zero('value')}
                bit = 0
              elsif (bit = bitmasks[:#{attribute}][value]).nil?
                raise ArgumentError, "Unsupported value for #{attribute}: \#{value.inspect}"
              end
              bitmask | bit
            end
          end

          def self.#{attribute}_for_bitmask(entry)
            size = self.bitmasks[:#{attribute}].size
            unless entry.is_a?(Fixnum) && entry.between?(0, (2 ** size) - 1)
              raise ArgumentError, "Unsupported value for #{attribute}: \#{entry.inspect}"
            end
            self.bitmasks[:#{attribute}].inject([]) do |values, (value, bitmask)|
              values.tap do
                values << value.to_sym if (entry & bitmask > 0)
              end
            end
          end
        )
      end

      def create_convenience_instance_methods_on(model)
        values.each do |value|
          model.class_eval %(
            def #{attribute}_for_#{value}?
              self.#{attribute}?(:#{value})
            end
          )
        end
        model.class_eval %(
          def #{attribute}?(*values)
            if !values.blank?
              values.all? do |value|
                if #{eval_string_for_zero('value')}
                  self.#{attribute}.blank?
                else
                  self.#{attribute}.include?(value)
                end
              end
            else
              self.#{attribute}.present?
            end
          end
        )
      end

      def create_scopes_on(model)
        or_is_null_condition = " OR #{attribute} IS NULL" if allow_null

        model.class_eval %(
          scope :with_#{attribute},
            proc { |*values|
              if values.blank?
                where('#{column_name_with_table(model)} > 0')
              else
                sets = values.map do |value|
                  if #{eval_string_for_zero('value')}
                    "#{column_name_with_table(model)} = 0"
                  else
                    mask = ::#{model}.bitmask_for_#{attribute}(value)
                    "#{column_name_with_table(model)} & \#{mask} <> 0"
                  end
                end
                where(sets.join(' AND '))
              end
            }
          scope :without_#{attribute},
            proc { |*values|
              if values.blank?
                no_#{attribute}
              else
                relation = where("#{column_name_with_table(model)} & ? = 0#{or_is_null_condition}", ::#{model}.bitmask_for_#{attribute}(*values))
                if values.any?{|value|#{eval_string_for_zero('value')}}
                  relation = relation.where("#{column_name_with_table(model)} > 0")
                end
                relation
              end
            }

          scope :with_exact_#{attribute},
            proc { | *values|
              if values.blank?
                no_#{attribute}
              else
                relation = where("#{column_name_with_table(model)} = ?", ::#{model}.bitmask_for_#{attribute}(*values))
                if values.any?{|value|#{eval_string_for_zero('value')}}
                  relation = relation.where("#{column_name_with_table(model)} = 0#{or_is_null_condition}")
                end
                relation
              end
            }

          scope :no_#{attribute}, proc { where("#{column_name_with_table(model)} = 0#{or_is_null_condition}") }

          scope :with_any_#{attribute},
            proc { |*values|
              if values.blank?
                where('#{column_name_with_table(model)} > 0')
              else
                clause = "#{attribute} & ? <> 0"
                if values.any?{|value|#{eval_string_for_zero('value')}}
                  clause += " OR #{column_name_with_table(model)} = 0#{or_is_null_condition}"
                end
                where(clause, ::#{model}.bitmask_for_#{attribute}(*values))
              end
            }
        )
        values.each do |value|
          model.class_eval %(
            scope :#{attribute}_for_#{value},
                  proc { where('#{column_name_with_table(model)} & ? <> 0', ::#{model}.bitmask_for_#{attribute}(:#{value})) }
          )
        end
      end

      def eval_string_for_zero(value_string)
        zero_value ? "#{value_string}.blank? || #{value_string}.to_s == '#{zero_value}'" : "#{value_string}.blank?"
      end

      def column_name_with_table(model)
        "#{model.table_name}.#{attribute}"
      end

  end
end
