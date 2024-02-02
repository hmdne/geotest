require "interscript"
require "interscript/compiler/ruby"
require "optparse"

class Interscript::GeoTest
  def initialize(file, verbose: false)
    @file = file
    @verbose = verbose
  end

  def start
    run read
    run group_by_ufi
    run group_by_uni
    run group_by_transl
    run cluster_by_related
    done
    # --- analysis ---
    analyze_uni_uniqueness
    analyze_related_clusters
    analyze_translit_systems
    analyze_usability_of_related_clusters
    analyze_good_clusters
  end

  def self.start(...) = new(...).start

  # Parse TSV into an array of structure instances
  def read
    records = File.read(@file).split(/\r?\n/).map { |i| i.split("\t") }
    headers = records.shift.map(&:downcase).map(&:to_sym)
    records = records.map { |i| i.map.with_index { |v,idx| [headers[idx], v] }.to_h }
    @records = records.map { |i| Name.new(self, **i) }
  end

  def run(*) = print "."
  def done = puts

  def group_by_ufi
    @records_by_ufi = @records.group_by(&:ufi)
  end

  def group_by_uni
    @records_by_uni = @records.group_by(&:uni)
  end

  def group_by_transl
    @records_by_transl = @records.group_by(&:transl_cd).sort_by { |_,v| -v.length }.to_h
  end

  def cluster_by_related
    @related_clusters = {}
    @records.each do |record|
      next unless record.related

      my_cluster = (
        (@related_clusters[record.uni] || []) +
        (@related_clusters[record.related.uni] || []) +
        [record, record.related]
      ).uniq(&:object_id)

      my_cluster.each { |r| @related_clusters[r.uni] = my_cluster }
    end

    @unique_related_clusters = @related_clusters.values.uniq(&:object_id)
  end

  attr_reader :records, :records_by_ufi, :records_by_uni, :records_by_transl, :related_clusters, :unique_related_clusters

  def analyze_uni_uniqueness
    count = @records_by_uni.values.select { |i| i.length > 1 }.count
    puts "#{count} records have a non-unique UNI (should be 0)"
    puts
  end

  def analyze_related_clusters
    puts "Out of #{@related_clusters.length} related clusters we get #{@unique_related_clusters.length} unique related clusters"
    puts "Unique clusters have #{@unique_related_clusters.map(&:length).sum} members in total (this should match a number of related clusters)"
    print "Hash of cluster length to a number of clusters of that kind: "
    p @unique_related_clusters.group_by(&:length).transform_values(&:length)
    puts
  end

  def analyze_usability_of_related_clusters
    errors = {
      length: [],
      no_transl: [],
      no_script: [],
      too_much_script: [],
      no_map: [],
    }
    good = []

    @unique_related_clusters.each do |cluster|
      if cluster.length < 2
        # A bug - likely due to wrong data
        errors[:length] << cluster
      elsif cluster.none? { |i| %w[NS DS VS].include? i.nt }
        # We can do nothing about it
        errors[:no_script] << cluster
      elsif cluster.none? { |i| i.transl_cd != '' }
        # TODO: Add some heuristics per run?
        errors[:no_transl] << cluster
      elsif cluster.count { |i| %w[NS DS VS].include? i.nt } > 1
        # TODO: split those by some heuristic like by LC
        errors[:too_much_script] << cluster
      elsif cluster.none? { |i| geo_to_is i.transl_cd }
        # We don't have a usable map for those entries
        errors[:no_map] << cluster
      else
        good << cluster
      end
    end

    puts "Among the unique clusters:"
    puts "- #{errors[:length].length} clusters are too short"
    puts "- #{errors[:no_script].length} clusters contain no non-ASCII entries"
    puts "- #{errors[:no_transl].length} clusters contain no transliteration info"
    puts "- #{errors[:too_much_script].length} clusters contain more than 1 non-ASCII entries"
    puts "- #{errors[:no_map].length} clusters are transliterated with a map not present in Interscript"
    puts "Remaining #{good.length} clusters seem to be usable"
    puts

    @good_clusters = good
  end

  def compare_and_return_error(first, second)
    if first == second
      nil
    elsif first.downcase == second.downcase
      "Incorrect casing"
    elsif first.gsub(/[^[:alpha:][:space:]]/,'') == second.gsub(/[^[:alpha:][:space:]]/,'')
      "Incorrect punctuation"
    elsif first.downcase.gsub(/[^[:alpha:][:space:]]/,'') == second.downcase.gsub(/[^[:alpha:][:space:]]/,'')
      "Incorrect casing and punctuation"
    elsif first.gsub(/[^[:alpha:]]/,'') == second.gsub(/[^[:alpha:]]/,'')
      "Incorrect spacing or punctuation"
    elsif first.downcase.gsub(/[^[:alpha:]]/,'') == second.downcase.gsub(/[^[:alpha:]]/,'')
      "Incorrect casing and (spacing or punctuation)"
    else
      "Incorrect transliteration"
    end
  end

  def analyze_good_clusters
    results = {}
    maps = {}

    @good_clusters.each do |cluster|
      cluster = cluster.dup

      original = cluster.find { |i| %w[NS DS VS].include? i.nt }
      cluster.delete(original)

      # The rest of entries in the cluster are transliterated entries
      cluster.each do |i|
        group = [original, i]
        transl = i.transl_cd
        results[transl] ||= []
        map_id = geo_to_is transl
        unless map_id
          results[transl] << {error: "No support in Interscript", group: group}
          next
        end
        compiler = Interscript.load(map_id, maps, compiler: Interscript::Compiler::Ruby)
        result_fnro = compiler.(original.full_name_ro)
        result_fnrg = compiler.(original.full_name_rg)

        if error = compare_and_return_error(result_fnro, i.full_name_ro)
          results[transl] << {error: error, group: group, result: [result_fnro, result_fnrg]}
        elsif error = compare_and_return_error(result_fnrg, i.full_name_rg)
          results[transl] << {error: error, group: group, result: [result_fnro, result_fnrg]}
        else
          results[transl] << {ok: true, group: group}
        end
      end
    end

    # Compare transliteration result
    results.each do |transl, results|
      print "#{transl}: "
      all = results.length
      good = results.select { |i| i[:ok] }.length
      errors = results.select { |i| i[:error] }
      print "#{good}/#{all} (#{(good*100.0/all).round(2)}%)"
      unless errors.empty?
        print " (Errors: "
        print errors.group_by { |i| i[:error] }.transform_values(&:length).map { |error, count|
          "#{error} * #{count}"
        }.join(", ")
        print ")"
      end
      puts

      if @verbose && !errors.empty?
        pp errors
      end
    end
  end

  def geo_to_is(name)
    (@geo_to_is_cache ||= {})[name] ||= begin
      File.basename(Interscript.locate(name), ".imp") rescue nil
    end
  end

  def analyze_translit_systems
    puts "Transliteration systems used:"
    @records_by_transl.each do |transl,names|
      print "- #{transl.inspect} * #{names.length} "
      print "(#{names.select { |i| i.related }.length} with a pair)"
      print " implemented in Interscript as #{geo_to_is transl}" if geo_to_is transl
      puts
    end
    puts
  end

  class Name
    FIELDS=%i[ufi uni mgrs nt lc full_name_ro full_name_rg name_link transl_cd]
    INT_FIELDS=%i[ufi uni name_link]
    attr_accessor *FIELDS

    def initialize(geotest, **kwargs)
      @geotest = geotest
      kwargs.each do |k,v|
        if INT_FIELDS.include?(k)
          v = v == '' ? nil : v.to_i
        end
        instance_variable_set(:"@#{k}", v)
      end
    end

    def inspect
      "#<Name #{FIELDS.map { |i| "#{i}=#{send(i)}" }.join(" ")}>"
    end

    def related
      return nil unless name_link
      @geotest.records_by_uni[name_link]&.first
    end

    def related_cluster
      @geotest.related_clusters[uni] || []
    end
  end
end

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options] file"

  opts.on("-v", "--verbose", "Describe all failures") do
    options[:verbose] = true
  end

  opts.on("-h", "--help", "Prints this help") do
    puts opts
    exit
  end
end.parse!(ARGV.empty? ? ["--help"] : ARGV)

file = ARGV[0]
Interscript::GeoTest.start(file, **options)
