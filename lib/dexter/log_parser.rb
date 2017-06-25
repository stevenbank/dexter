module Dexter
  class LogParser
    REGEX = /duration: (\d+\.\d+) ms  (statement|execute <unnamed>): (.+)/

    def initialize(logfile, client)
      @logfile = logfile
      @min_time = client.options[:min_time] * 60000 # convert minutes to ms
      @top_queries = {}
      @indexer = Indexer.new(client)
      @new_queries = Set.new
      @new_queries_mutex = Mutex.new
      @process_queries_mutex = Mutex.new
      @last_checked_at = {}

      log "Started"

      if @logfile == STDIN
        Thread.abort_on_exception = true

        @timer_thread = Thread.new do
          sleep(3) # starting sleep
          loop do
            @process_queries_mutex.synchronize do
              process_queries
            end
            sleep(client.options[:interval])
          end
        end
      end
    end

    def perform
      active_line = nil
      duration = nil

      each_line do |line|
        if active_line
          if line.include?(":  ")
            process_entry(active_line, duration)
            active_line = nil
            duration = nil
          else
            active_line << line
          end
        end

        if !active_line && m = REGEX.match(line.chomp)
          duration = m[1].to_f
          active_line = m[3]
        else
          # skip
        end
      end
      process_entry(active_line, duration) if active_line

      @process_queries_mutex.synchronize do
        process_queries
      end
    end

    private

    def each_line
      if @logfile == STDIN
        STDIN.each_line do |line|
          yield line
        end
      else
        File.foreach(@logfile) do |line|
          yield line
        end
      end
    end

    def process_entry(query, duration)
      return unless query =~ /SELECT/i
      fingerprint =
        begin
          PgQuery.fingerprint(query)
        rescue PgQuery::ParseError
          # do nothing
        end
      return unless fingerprint

      @top_queries[fingerprint] ||= {calls: 0, total_time: 0}
      @top_queries[fingerprint][:calls] += 1
      @top_queries[fingerprint][:total_time] += duration
      @top_queries[fingerprint][:query] = query
      @new_queries_mutex.synchronize do
        @new_queries << fingerprint
      end
    end

    def process_queries
      new_queries = nil

      @new_queries_mutex.synchronize do
        new_queries = @new_queries.dup
        @new_queries.clear
      end

      now = Time.now
      min_checked_at = now - 3600 # don't recheck for an hour
      queries = []
      fingerprints = {}
      @top_queries.each do |k, v|
        if new_queries.include?(k) && v[:total_time] > @min_time && (!@last_checked_at[k] || @last_checked_at[k] < min_checked_at)
          fingerprints[v[:query]] = k
          queries << v[:query]
          @last_checked_at[k] = now
        end
      end

      log "Processing #{queries.size} new query fingerprints"
      if queries.any?
        @indexer.process_queries(queries)
      end
    end

    def log(message)
      puts "#{Time.now.iso8601} #{message}"
    end
  end
end
