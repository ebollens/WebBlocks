require 'extend_method'
require 'web_blocks/facade/block'
require 'web_blocks/framework'
require 'web_blocks/structure/tree/node'
require 'web_blocks/structure/attribute/dependency'
require 'web_blocks/structure/attribute/loose_dependency'
require 'web_blocks/structure/attribute/reverse_dependency'
require 'web_blocks/structure/attribute/reverse_loose_dependency'

module WebBlocks
  module Structure
    class BlockCore < ::WebBlocks::Structure::Tree::Node

      class << self
        include ExtendMethod
      end

      include WebBlocks::Framework

      include WebBlocks::Structure::Attribute::Dependency
      include WebBlocks::Structure::Attribute::LooseDependency
      include WebBlocks::Structure::Attribute::ReverseDependency
      include WebBlocks::Structure::Attribute::ReverseLooseDependency

      ##
      # Methods supporting extending the block DSL with facades for non-primitive blocks
      #

      def register_facade name, handler
        @facade_map = {} unless (defined?(@facade_map) and @facade_map)
        @facade_map[name.to_sym] = handler
      end

      def self.register_facade name, handler
        @@class_facade_map = {} unless defined? @@class_facade_map
        @@class_facade_map[name.to_sym] = handler
      end

      def resolve_facade name
        if @facade_map and @facade_map.has_key?(name)
          @facade_map[name]
        elsif parent
          parent.resolve_facade name
        else
          nil
        end
      end

      def resolve_class_facade name
        if @@class_facade_map and @@class_facade_map[name]
          @@class_facade_map[name]
        elsif parent
          parent.resolve_class_facade name
        else
          nil
        end
      end

      def isolated_facade_registration_scope &block
        facade_map = @facade_map
        begin
          instance_eval &block
          @facade_map = facade_map
        rescue => e
          @facade_map = facade_map
          raise e
        end
      end

      def method_missing name, *arguments, &block
        handler_class = resolve_facade(name)
        handler_class = resolve_class_facade(name) unless handler_class
        raise NoMethodError, "undefined facade `#{name}' for #{self}" unless handler_class
        handler = handler_class.new(self)
        handler.handle *arguments, &block
      end

      ##
      # Methods supporting pathing enabled by WebBlocks::Structure::Framework#register
      #

      def scoped_base_path
        if defined?(@isolated_from_parent_scoped_base_path)
          nil
        elsif defined?(@scoped_base_path)
          @scoped_base_path
        elsif parent
           parent.scoped_base_path
        else
          nil
        end
      end

      def has_scoped_base_path?
        return false if defined? @isolated_from_parent_scoped_base_path
        return true if defined? @scoped_base_path
        return true if (parent and parent.has_scoped_base_path?)
        return false
      end

      def set_scoped_base_path path
        @scoped_base_path = path
      end

      def isolate_subgraph_from_scoped_base_path!
        @isolated_from_parent_scoped_base_path = true
      end

      def forget_scoped_base_path!
        remove_instance_variable :@scoped_base_path if defined? @scoped_base_path
        remove_instance_variable :@isolated_from_parent_scoped_base_path if defined? @isolated_from_parent_scoped_base_path
        parent.forget_scoped_base_path! if parent
      end

      def with_base_path base_path, &block
        set_scoped_base_path base_path
        klass = Class.new(::WebBlocks::Facade::Block)
        klass.class_variable_set :@@default_base_path, base_path
        klass.class_eval do
          def handle *params, &block
            subblock = super *params, &block
            default_base_path = self.class.class_variable_get(:@@default_base_path).to_s
            subblock.define_singleton_method(:default_base_path){ default_base_path }
            subblock
          end
        end
        register_facade :block, klass
        instance_eval &block
        register_facade :block, ::WebBlocks::Facade::Block
        forget_scoped_base_path!
      end

      # Extending set_parent method from WebBlocks::Support::Attributes::Container, which is included by way of
      # inheritance through self.class -> WebBlocks::Structure::Tree::Node -> WebBlocks::Structure::Tree::LeafNode.
      # This is required for WebBlocks::Structure::Framework#register.

      extend_method :set_parent do |parent|
        parent_method parent
        if has_scoped_base_path?
          if has? :path
            path = get(:path).to_s
            set :path, "#{scoped_base_path}/#{path}" unless path[0,1] == '/'
            isolate_subgraph_from_scoped_base_path!
          end
        end
      end

      ##
      # Methods available for interpreting and manipulating the block
      #

      def resolved_path

        parents_except_root = parents

        # we're not going to use the root's path for determining if there's an implicit path
        root = parents_except_root.pop

        # get the sub-paths
        subpaths = []
        parents_except_root.each do |p|
          subpaths.unshift(p.get(:path)) if p.has?(:path)
        end

        if subpaths.length == 0
          [self, parents_except_root].flatten.each do |p|
            if p.respond_to? :default_base_path
              subpaths.push(p.default_base_path)
              break
            end
          end
        end

        subpaths.unshift(Pathname.new((root and root.has?(:path)) ? root.get(:path) : '.'))

        subpaths << attributes[:path] if attributes.has_key?(:path)

        begin
          subpaths.reduce(:+).realpath
        rescue => e
          puts "Error resolving block #{self.route} to path #{subpaths.reduce(:+).to_json} from #{subpaths.to_json}"
          raise e
        end

      end

      def files
        computed = []
        children.each do |name,object|
          if object.is_a? Block
            computed = computed + object.files
          elsif object.is_a? RawFile
            computed << object
          end
        end
        computed
      end

      def select_leaf_nodes branch_select_proc, leaf_select_proc
        leaf_nodes = []
        nodes = [self]
        while nodes.length > 0
          node = nodes.pop
          if node.respond_to? :children
            nodes |= node.children.values.select(&branch_select_proc)
          elsif leaf_select_proc.call(node)
            leaf_nodes << node
          end
        end
        leaf_nodes
      end

      def required_files
        select_leaf_nodes Proc.new(){ |node| node.get(:required) }, Proc.new(){ |node| node.is_a? RawFile }
      end

      def child_add_or_update klass, name, attributes = {}
        unless has_child? name
          add_child klass.new(name, attributes)
        else
          attributes.each { |key, value| children[name].set key, value }
        end
        children[name]
      end

      def child_eval klass, name, attributes = {}, block
        child = child_add_or_update klass, name, attributes
        child.instance_exec children[name], &block if block
        child
      end

    end
  end
end