require "interscript"
require "interscript/compiler/ruby"
require "optparse"
require "csv"

class Interscript::GeoTest
  def initialize(file, verbose: false, report_bugs: false, error_file: nil)
    @file = file
    @verbose = verbose
    @errors = []
    @report_bugs = report_bugs
    @error_file = error_file
    @last_id = 0
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
    # --- output ---
    output_found_errors
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
    duplicates = @records_by_uni.values.select { |i| i.length > 1 }
    puts "#{duplicates.count} records have a non-unique UNI (should be 0)"
    duplicates.each do |name|
      add_error :uni_duplicate, name
    end
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
        add_error :length, cluster
        errors[:length] << cluster
      elsif cluster.none?(&:script?)
        # We can do nothing about it
        add_error :no_script, cluster
        errors[:no_script] << cluster
      elsif cluster.none? { |i| i.transl_cd != '' }
        # TODO: Add some heuristics per run?
        add_error :no_transl, cluster
        errors[:no_transl] << cluster
      elsif cluster.count(&:script?) > 1
        # TODO: split those by some heuristic like by LC
        add_error :too_much_script, cluster
        errors[:too_much_script] << cluster
      elsif cluster.none? { |i| geo_to_is i.transl_cd }
        # We don't have a usable map for those entries
        add_error :no_map, cluster
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

  def compare_and_return_error(first, second, group)
    if first == second
      nil
    elsif first.downcase == second.downcase
      add_error :casing, group, attempted_transliteration: first
      "Incorrect casing"
    elsif first.gsub(/[^[:alpha:][:space:]]/,'') == second.gsub(/[^[:alpha:][:space:]]/,'')
      add_error :punctuation, group, attempted_transliteration: first
      "Incorrect punctuation"
    elsif first.downcase.gsub(/[^[:alpha:][:space:]]/,'') == second.downcase.gsub(/[^[:alpha:][:space:]]/,'')
      add_error :casing_and_punctuation, group, attempted_transliteration: first
      "Incorrect casing and punctuation"
    elsif first.gsub(/[^[:alpha:]]/,'') == second.gsub(/[^[:alpha:]]/,'')
      add_error :spacing_or_punctuation, group, attempted_transliteration: first
      "Incorrect spacing or punctuation"
    elsif first.downcase.gsub(/[^[:alpha:]]/,'') == second.downcase.gsub(/[^[:alpha:]]/,'')
      add_error :casing_and_spacing_or_punctuation, group, attempted_transliteration: first
      "Incorrect casing and (spacing or punctuation)"
    else
      add_error :transliteration, group, attempted_transliteration: first
      "Incorrect transliteration"
    end
  end

  def analyze_good_clusters
    results = {}
    $maps ||= {}

    @good_clusters.each do |cluster|
      cluster = cluster.dup

      original = cluster.find(&:script?)
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
        compiler = Interscript.load(map_id, $maps, compiler: Interscript::Compiler::Ruby)
        result_fn = compiler.(original.full_name)

        if error = compare_and_return_error(result_fn, i.full_name, group)
          results[transl] << {error: error, group: group, result: result_fn}
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

  def output_found_errors
    if @error_file
      errors = @errors.map(&:to_h)

      CSV.open(@error_file, "wb", col_sep: "\t") do |csv|
        csv << Error::KEYS
        errors.each do |hash|
          csv << hash.values
        end
      end
    end
  end

  def add_error(type, names, **kwargs)
    # Skip reporting Interscript bugs by default
    return if !@report_bugs && %i[no_map].include?(type)

    names = Array(names)
    @last_id += 1
    names.each do |name|
      @errors << Error.new(@last_id, type, name, **kwargs)
    end
  end

  class Name
    FIELDS=%i[ufi uni mgrs nt lang_cd full_name name_link transl_cd script_cd]
    INT_FIELDS=%i[ufi uni name_link]
    attr_accessor *FIELDS

    alias lc lang_cd

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

    def script?
      %w[NS DS VS].include? nt
    end
  end

  class Error
    KEYS=%i[error_id error_type ufi uni nt full_name lang_cd transl_cd script_cd
            attempted_transliteration other_matching_maps]

    def initialize(id, type, name, attempted_transliteration: nil)
      @id, @type, @name = id, type, name
      @attempted_transliteration = attempted_transliteration
    end
    attr_reader :id, :type, :name, :attempted_transliteration, :other_matching_maps

    def determine_other_matching_maps
      return if name.script?

      script_name = name.related_cluster.find(&:script?).full_name
      transliterated_name = name.full_name

      if name.lang_cd == ""
        $stderr.puts "* Warning: a record with UFI #{name.ufi} has no lang_cd. Trying all maps - may take some time."
      end

      result = Interscript.detect(
        script_name,
        transliterated_name,
        compiler: Interscript::Compiler::Ruby,
        cache: $cache,
        multiple: true,
        map_pattern: name.lang_cd != "" ? "*-#{name.lang_cd}-*" : "*"
      )
      result = result.select { |_,v| v == 0 }.to_h.keys
      result = result.join(", ")
      @other_matching_maps = result
    end

    def to_h
      if %i[no_transl transliteration].include? type
        determine_other_matching_maps
      end

      {error_id: id,
       error_type: type,

       ufi: name.ufi,
       uni: name.uni,
       nt: name.nt,
       full_name: name.full_name,
       lang_cd: name.lang_cd,
       transl_cd: name.transl_cd,
       script_cd: name.script_cd,

       attempted_transliteration: attempted_transliteration,
       other_matching_maps: other_matching_maps
      }
    end
  end
end

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options] file"

  # This function is obsolete. Please use the error file facility.
  # opts.on("-v", "--verbose", "Describe all failures") do
  #   options[:verbose] = true
  # end

  opts.on("-b", "--bugs", "Report interscript bugs in error file") do
    options[:report_bugs] = true
  end

  opts.on("-o", "--output=FILE", "Output the analysis summary to FILE") do |file|
    $stdout = File.open(file, 'w')
  end

  opts.on("-e", "--error-file=FILE", "Generate a TSV error file, containing all found errors") do |file|
    options[:error_file] = file
  end

  opts.on("-h", "--help", "Prints this help") do
    puts opts
    exit
  end
end.parse!(ARGV.empty? ? ["--help"] : ARGV)

file = ARGV[0]
Interscript::GeoTest.start(file, **options)
