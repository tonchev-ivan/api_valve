module ApiValve
  class Proxy
    include ActiveSupport::Callbacks

    FORWARDER_OPTIONS = %w(endpoint request response permission_handler).freeze

    class_attribute :permission_handler, :request, :response
    self.permission_handler = Forwarder::PermissionHandler
    self.request = Forwarder::Request
    self.response = Forwarder::Response

    class << self
      # Creates a n instance from a config hash and takes optional block
      # which is executed in scope of the proxy
      def build(config)
        block = Proc.new if block_given? # capture the yield
        from_hash(config).tap do |proxy|
          proxy.instance_eval(&block) if block
        end
      end

      def from_config(file_name = nil)
        file_name ||= name.underscore
        path = find_config(file_name)
        raise "Config not found for #{name.underscore}(.yml|.yml.erb) in #{ApiValve.config_paths.inspect}" unless path

        yaml = File.read(path)
        yaml = ERB.new(yaml, nil, '-').result if path.fnmatch? '*.erb'
        from_yaml yaml
      end

      def from_yaml(string)
        from_hash YAML.load(string) # rubocop:disable Security/YAMLLoad
      end

      def from_hash(config)
        config = config.with_indifferent_access
        forwarder = Forwarder.new(forwarder_config(config))
        new(forwarder).tap do |proxy|
          Array.wrap(config[:use]).each { |mw| proxy.use mw }
          proxy.build_routes_from_config config[:routes]
        end
      end

      private

      def find_config(file_name)
        ApiValve.config_paths.each do |dir|
          path = dir.join("#{file_name}.yml")
          return path if path.exist?

          path = dir.join("#{file_name}.yml.erb")
          return path if path.exist?
        end
        nil
      end

      def forwarder_config(config)
        {
          permission_handler: {klass: permission_handler},
          request:            {klass: request},
          response:           {klass: response}
        }.with_indifferent_access.deep_merge config.slice(*FORWARDER_OPTIONS)
      end
    end

    attr_reader :request, :forwarder, :router

    def initialize(forwarder)
      @forwarder = forwarder
      @router = Router.new
      @middlewares = []
    end

    def call(env)
      stack = @middlewares.reverse.inject(@router) { |a, e| e.call a }
      stack.call(env)
    rescue ApiValve::Error::Client, ApiValve::Error::Server => e
      render_error e
    end

    delegate :add_route, to: :router

    def build_routes_from_config(routes_config)
      return forward_all unless routes_config

      routes_config.each do |route_config|
        method, path_regexp, request_override = *route_config.values_at('method', 'path', 'request')
        method ||= 'any' # no method defined means all methods
        if route_config['raise']
          deny method, path_regexp, with: route_config['raise']
        else
          forward method, path_regexp, request_override
        end
      end
    end

    def forward(methods, path_regexp = nil, request_override = {})
      Array.wrap(methods).each do |method|
        router.public_send(method, path_regexp, proc { |request, match_data|
          forwarder.call request, {'match_data' => match_data}.merge(request_override || {})
        })
      end
    end

    def forward_all
      router.any do |request, match_data|
        forwarder.call request, 'match_data' => match_data
      end
    end

    def deny(methods, path_regexp = nil, with: 'Error::Forbidden')
      Array.wrap(methods).each do |method|
        router.public_send(method, path_regexp, ->(*_args) { raise ApiValve.const_get(with) })
      end
    end

    def use(middleware, *args, &block)
      @middlewares << proc { |app| middleware.new(app, *args, &block) }
    end

    protected

    def render_error(error)
      self.class.const_get(ApiValve.error_responder).new(error).call
    end
  end
end
