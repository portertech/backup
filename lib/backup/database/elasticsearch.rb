# encoding: utf-8

module Backup
  module Database
    class Elasticsearch < Base

      require 'net/http'

      ##
      # Elasticsearch data directory path.
      #
      # This is set in `elasticsearch.yml`.
      #   path:
      #     data: /var/data/elasticsearch
      #
      # eg. /var/data/elasticsearch
      #
      attr_accessor :path

      ##
      # Elasticsearch index name to backup.
      #
      # To backup all indexes, set this to `:all` or leave blank.
      #
      attr_accessor :index

      ##
      # Determines whether Backup should flush the index with the
      # Elasticsearch API before copying the index directory.
      #
      attr_accessor :invoke_flush

      ##
      # Determines whether Backup should enable/disable flushing the index with
      # Elasticsearch API before/after copying the index directory.
      #
      attr_accessor :disable_flushing
      ##
      # Determines whether Backup should close the index with the
      # Elasticsearch API before copying the index directory.
      #
      attr_accessor :invoke_close

      ##
      # Elasticsearch API options for the +invoke_flush+ and
      # +invoke_close+ options.
      attr_accessor :host, :port

      def initialize(model, database_id = nil, &block)
        super
        instance_eval(&block) if block_given?

        @index ||= :all
        @host ||= 'localhost'
        @port ||= 9200
      end

      ##
      # Tars and optionally compresses the Elasticsearch index
      # folder to the +dump_path+ using the +dump_filename+.
      #
      #   <trigger>/databases/Eliasticsearch[-<database_id>].tar[.gz]
      #
      # If +invoke_flush+ is true, `POST $index/_flush` will be invoked.
      # If +invoke_close+ is true, `POST $index/_close` will be invoked.
      def perform!
        super

        invoke_flush! if invoke_flush
        disable_flushing!(true) if disable_flushing
        unless backup_all?
          invoke_close! if invoke_close
        end
        copy!
        disable_flushing!(false) if disable_flushing

        log!(:finished)
      end

      private

      def backup_all?
        [:all, ':all', 'all'].include?(index)
      end

      def api_request(http_method, endpoint, body=nil)
        http = Net::HTTP.new(host, port)
        request = case http_method.to_sym
        when :post
          Net::HTTP::Post.new(endpoint)
        when :put
          Net::HTTP::Put.new(endpoint, initheader = {'Content-Type' => 'application/json'})
        end
        request.body = body
        begin
          Timeout::timeout(180) do
            http.request(request)
          end
        rescue => error
          raise Errors::Database::Elasticsearch::QueryError, <<-EOS
            Could not query the Elasticsearch API.
            Host was: #{ host }
            Port was: #{ port }
            Endpoint was: #{ endpoint }
            Error was: #{ error.message }
          EOS
        end
      end

      def update_settings_endpoint
        backup_all? ? '/_settings' : "/#{ index }/_settings"
      end

      def disable_flushing!(disable)
        body = '{ "index" : { "translog.disable_flush" : "' + disable.to_s + '" } }'
        response = api_request(:put, update_settings_endpoint, body)
        unless response.code == '200'
          raise Errors::Database::Elasticsearch::QueryError, <<-EOS
            Could not update flush settings of the the Elasticsearch index.
            Host was: #{ host }
            Port was: #{ port }
            Endpoint was: #{ update_settings_endpoint }
            Response body was: #{ response.body }
            Response code was: #{ response.code }
          EOS
        end
      end

      def flush_index_endpoint
        backup_all? ? '/_flush' : "/#{ index }/_flush"
      end

      def invoke_flush!
        response = api_request(:post, flush_index_endpoint)
        unless response.code == '200'
          raise Errors::Database::Elasticsearch::QueryError, <<-EOS
            Could not flush the Elasticsearch index.
            Host was: #{ host }
            Port was: #{ port }
            Endpoint was: #{ flush_index_endpoint }
            Response body was: #{ response.body }
            Response code was: #{ response.code }
          EOS
        end
      end

      def close_index_endpoint
        "/#{ index }/_close"
      end

      def invoke_close!
        response = api_request(:post, close_index_endpoint)
        unless response.code == '200'
          raise Errors::Database::Elasticsearch::QueryError, <<-EOS
            Could not close the Elasticsearch index.
            Host was: #{ host }
            Port was: #{ port }
            Endpoint was: #{ close_index_endpoint }
            Response body was: #{ response.body }
            Response code was: #{ response.code }
          EOS
        end
      end

      def copy!
        src_path = File.join(path, 'nodes/0/indices')
        src_path = File.join(src_path, index) unless backup_all?
        unless File.exist?(src_path)
          raise Errors::Database::Elasticsearch::NotFoundError, <<-EOS
            Elasticsearch index directory not found
            Directory path was #{ src_path }
          EOS
        end
        pipeline = Pipeline.new
        pipeline << "#{ utility(:tar) } -cf - #{ src_path }"
        dst_ext = '.tar'
        if model.compressor
          model.compressor.compress_with do |cmd, ext|
            pipeline << cmd
            dst_ext << ext
          end
        end
        dst_path = File.join(dump_path, dump_filename + dst_ext)
        pipeline << "#{ utility(:cat) } > '#{ dst_path }'"
        pipeline.run
        unless pipeline.success?
          raise Errors::Database::PipelineError,
            "Elasticsearch Index '#{ index }' Backup Failed!\n" + pipeline.error_messages
        end
      end

    end
  end
end
