require 'action_controller'

module ActionController
  module Routing
    class RouteSet
      NotFound = lambda { |env|
        raise RoutingError, "No route matches #{env[::Rack::Mount::Const::PATH_INFO].inspect} with #{env.inspect}"
      }

      class Dispatcher
        def initialize(options = {})
          defaults = options[:defaults]
          @glob_param = options.delete(:glob)
          @app = controller(defaults) if bind_controller_const?
        end

        def call(env)
          params = env[::Rack::Mount::Const::RACK_ROUTING_ARGS]
          app = @app || controller(params)
          merge_default_action!(params)
          split_glob_param!(params) if @glob_param

          # TODO: Rails response is not finalized by the controller
          app.call(env).to_a
        end

        private
          def bind_controller_const?
            if defined? Rails
              Rails.env.production?
            else
              true
            end
          end

          def controller(params)
            if params && params.has_key?(:controller)
              controller = "#{params[:controller].camelize}Controller"
              ActiveSupport::Inflector.constantize(controller)
            end
          end

          def merge_default_action!(params)
            params[:action] ||= 'index'
          end

          def split_glob_param!(params)
            params[@glob_param] = params[@glob_param].split('/')
          end
      end

      module RouteExtensions
        def segment_keys
          path.names.compact.map(&:to_sym)
        end
      end

      class NamedRouteCollection
        private
          def generate_optimisation_block(*args)
          end
      end

      def draw
        yield Mapper.new(self)
        @set.add_route(NotFound, :path => /.*/)
        install_helpers
        @set.freeze
      end

      def clear!
        routes.clear
        named_routes.clear
        @combined_regexp = nil
        @routes_by_controller = nil
        @set = ::Rack::Mount::RouteSet.new
      end

      def add_route(path, options = {})
        clear! unless @set

        if path.is_a?(String)
          path = path.gsub('.:format', '(.:format)')
          path = optionalize_trailing_dynamic_segments(path)
        end

        if conditions = options.delete(:conditions)
          method = conditions.delete(:method)
        end

        name = options.delete(:name)

        requirements = options.delete(:requirements) || {}
        defaults = {}
        options.each do |k, v|
          if v.is_a?(Regexp)
            requirements[k.to_sym] = options.delete(k)
          else
            defaults[k.to_sym] = options.delete(k)
          end
        end

        if path.is_a?(String)
          glob = $1.to_sym if path =~ /\/\*(\w+)$/
          path = ::Rack::Mount::Utils.convert_segment_string_to_regexp(path, requirements, %w( / . ? ))
        end

        app = Dispatcher.new(:defaults => defaults, :glob => glob)

        conditions = { :method => method, :path => path }
        route = @set.add_route(app, conditions, defaults, name)
        route.extend(RouteExtensions)
        route
      end

      def add_named_route(name, path, options = {})
        options[:name] = name
        named_routes[name.to_sym] = add_route(path, options)
      end

      def generate(options, recall = {}, method = :generate)
        named_route = options.delete(:use_route)
        expire_on = build_expiry(options, recall)
        expire_on.each { |k, v| recall.delete(k) unless v }
        options = recall.merge(options)
        options.each { |k, v| options[k] = v.to_param }
        @set.url_for(named_route, options)
      end

      def url_for(*args)
        @set.url_for(*args)
      end

      def call(env)
        @set.call(env)
      end

      private
        def optionalize_trailing_dynamic_segments(path)
          path = (path =~ /^\//) ? path.dup : "/#{path}"
          optional, segments = true, []

          old_segments = path.split('/')
          old_segments.shift
          length = old_segments.length

          old_segments.reverse.each_with_index do |segment, index|
            if optional && !(segment =~ /^:\w+$/) && !(segment =~ /^:\w+\(\.:format\)$/)
              optional = false
            end

            if optional && index < length - 1
              segments.unshift('(/', segment)
              segments.push(')')
            else
              segments.unshift('/', segment)
            end
          end

          segments.join
        end
    end
  end
end
