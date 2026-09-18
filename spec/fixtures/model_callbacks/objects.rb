# frozen_string_literal: true

# Real Rails callback objects. Every hook raises if extraction executes it.
module ModelCallbackObjects
  class Named
    def before_save(_record)
      raise 'Callback must not execute during extraction'
    end

    def self.before_save(_record)
      raise 'Callback must not execute during extraction'
    end
  end

  class Labeled < Named
    def initialize(label)
      super()
      @label = label
    end

    def to_s
      @label
    end
  end

  class CustomClass < Named
    def self.to_s
      'custom callback class'
    end
  end

  def self.register(model)
    anonymous = Class.new(Named)
    namespace = Module.new
    namespace.define_singleton_method(:before_save) { |_record| raise 'Callback must not execute during extraction' }
    nested = namespace.const_set(:Nested, Class.new(Named))
    filters = [Named.new, Named.new, Named, anonymous, anonymous.new, namespace, nested, nested.new,
               Labeled.new('first callback'), Labeled.new('second callback'),
               Labeled.new('#<ModelCallbackObjects::Labeled:0x1234>'), CustomClass]
    filters.each { |filter| model.before_save(filter) }
    ['#<ModelCallbackObjects::Named>', '#<ModelCallbackObjects::Named>', 'ModelCallbackObjects::Named',
     '#<Class>', '#<#<Class>>', '#<Module>', '#<Module>::Nested', '#<#<Module>::Nested>',
     'first callback', 'second callback',
     '#<ModelCallbackObjects::Labeled:0x1234>', 'custom callback class']
  end
end
