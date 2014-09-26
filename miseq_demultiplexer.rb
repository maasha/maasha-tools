#!/usr/bin/env ruby

require 'biopieces'
require 'optparse'
require 'csv'
require 'google_hash'

USAGE = <<USAGE
  This program demultiplexes Illumina Paired data given a samples file and four
  FASTQ files containing forward and reverse index data and forward and reverse
  read data.
  
  The samples file consists of three tab-separated columns: sample_id, forward
  index, reverse inded).

  The FASTQ files are generated by the Illumina MiSeq instrument by adding the
  following key:

    <add key="CreateFastqForIndexReads" value="1">
  
  To the `MiSeq Reporter.exe.config` file located in the `MiSeq Reporter`
  installation folder, `C:\\Illumina\\MiSeqReporter` and restarting the
  `MiSeq Reporter` service. See the MiSeq Reporter User Guide page 29:
  
  http://support.illumina.com/downloads/miseq_reporter_user_guide_15042295.html

  Thus Basecalling using a SampleSheet.csv containing a single entry `Data` with
  no index information will generate the following files:
  
    Data_S1_L001_I1_001.fastq.gz
    Data_S1_L001_I2_001.fastq.gz
    Data_S1_L001_R1_001.fastq.gz
    Data_S1_L001_R2_001.fastq.gz
    Undetermined_S0_L001_I1_001.fastq.gz
    Undetermined_S0_L001_I2_001.fastq.gz
    Undetermined_S0_L001_R1_001.fastq.gz
    Undetermined_S0_L001_R2_001.fastq.gz

  Demultiplexing will generate file pairs according to the sample information
  in the samples file and input file suffix, one pair per sample, and these
  will be output in the same directory.
  
  It is possible to allow up to three mismatches per index. Also, read pairs are
  discared if either of the indexes have a mean quality score below a given
  threshold or any single position in the index have a quality score below a 
  given theshold.

  Two files `Undetermined_forward.tsv` and `Undetermined_reverse.tsv` are also
  output containing the count of unmatched indexes.

  Usage: #{File.basename(__FILE__)} [options] <FASTQ files>

  Example: #{File.basename(__FILE__)} -m samples.tsv Data*.fastq.gz

  Options:
USAGE

DEFAULT_SCORE_MIN  = 15
DEFAULT_SCORE_MEAN = 16
DEFAULT_MISMATCHES = 1

def suffix_extract(file, options)
  if file =~ /.+(_S\d_L\d{3}_R[12]_\d{3}).+$/
    suffix = $1
    case options[:compress]
    when /gzip/
      suffix << ".fastq.gz"
    when /bzip2/
      suffix << ".fastq.bz2"
    else
      suffix << ".fastq"
    end
  else
    raise RuntimeError, "Unable to parse file suffix from: #{file}"
  end

  suffix
end

def hash_index(index)
  index.tr("ATCG", "0123").to_i
end

def permutate(list, options = {})
  permutations = options[:permutations] || 2
  alphabet     = options[:alphabet]     || "ATCG"

  permutations.times do
    hash = list.inject({}) { |memo, obj| memo[obj.to_sym] = true; memo }

    list.each do |word|
      (0 ... word.size).each do |pos|
        alphabet.each_char do |char|
          new_word = word[0 ... pos] + char + word[ pos + 1 .. -1]

          hash[new_word.to_sym] = true
        end
      end
    end

    list = hash.keys.map { |k| k.to_s }
  end

  list
end

ARGV << "-h" if ARGV.empty?

options = {}

OptionParser.new do |opts|
  opts.banner = USAGE

  opts.on("-h", "--help", "Display this screen" ) do
    $stderr.puts opts
    exit
  end

  opts.on("-m", "--samples_file <file>", String, "Path to mapping file") do |o|
    options[:samples_file] = o
  end

  opts.on("--mismatches_max <uint>", Integer, "Maximum mismatches_max allowed (default=#{DEFAULT_MISMATCHES})") do |o|
    options[:mismatches_max] = o
  end

  opts.on("--scores_min <uint>", Integer, "Drop reads if a single position in the index have a quality score below scores_min (default=#{DEFAULT_SCORE_MIN})") do |o|
    options[:scores_min] = o
  end

  opts.on("--scores_mean <uint>", Integer, "Drop reads if the mean index quality score is below scores_mean (default=#{DEFAULT_SCORE_MEAN})") do |o|
    options[:scores_mean] = o
  end

  opts.on("-o", "--output_dir <dir>", String, "Output directory") do |o|
    options[:output_dir] = o
  end

  opts.on("-c", "--compress <gzip|bzip2>", String, "Compress output using gzip or bzip2 (default=<no compression>)") do |o|
    options[:compress] = o.to_sym
  end

  opts.on("-v", "--verbose", "Verbose output") do |o|
    options[:verbose] = o
  end
end.parse!

options[:mismatches_max] ||= DEFAULT_MISMATCHES
options[:scores_min]     ||= DEFAULT_SCORE_MIN
options[:scores_mean]    ||= DEFAULT_SCORE_MEAN
options[:output_dir]     ||= Dir.pwd

Dir.mkdir options[:output_dir] unless File.directory? options[:output_dir]

raise OptionParser::MissingArgument, "No samples_file specified."                                      unless options[:samples_file]
raise OptionParser::InvalidArgument, "No such file: #{options[:samples_file]}"                         unless File.file? options[:samples_file]
raise OptionParser::InvalidArgument, "mismatches_max must be >= 0 - not #{options[:mismatches_max]}"   unless options[:mismatches_max] >= 0
raise OptionParser::InvalidArgument, "mismatches_max must be <= 3 - not #{options[:mismatches_max]}"   unless options[:mismatches_max] <= 3
raise OptionParser::InvalidArgument, "scores_min must be >= 0 - not #{options[:scores_min]}"           unless options[:scores_min]     >= 0
raise OptionParser::InvalidArgument, "scores_min must be <= 40 - not #{options[:scores_min]}"          unless options[:scores_min]     <= 40
raise OptionParser::InvalidArgument, "scores_mean must be >= 0 - not #{options[:scores_mean]}"         unless options[:scores_mean]    >= 0
raise OptionParser::InvalidArgument, "scores_mean must be <= 40 - not #{options[:scores_mean]}"        unless options[:scores_mean]    <= 40

if options[:compress]
  unless options[:compress] =~ /^gzip|bzip2$/
    raise OptionParser::InvalidArgument, "Bad argument to --compress: #{options[:compress]}"
  end
end

fastq_files = ARGV.dup

raise ArgumentError, "Expected 4 input files - not #{fastq_files.size}" if fastq_files.size != 4

index1_file = fastq_files.grep(/_I1_/).first
index2_file = fastq_files.grep(/_I2_/).first
read1_file  = fastq_files.grep(/_R1_/).first
read2_file  = fastq_files.grep(/_R2_/).first

suffix1 = suffix_extract(read1_file, options)
suffix2 = suffix_extract(read2_file, options)

if read2_file =~ /.+(_S\d_L\d{3}_R2_\d{3}).+$/
  suffix2 = $1
  case options[:compress]
  when /gzip/
    suffix2 << ".fastq.gz"
  when /bzip2/
    suffix2 << ".fastq.bz2"
  else
    suffix2 << ".fastq"
  end
else
  raise RuntimeError, "Unable to parse file suffix"
end

samples = CSV.read(options[:samples_file], col_sep: "\t")

if options[:mismatches_max] <= 1
  index_hash = GoogleHashSparseLongToInt.new
else
  index_hash = GoogleHashDenseLongToInt.new
end

file_hash  = {}

samples.each_with_index do |sample, i|
  index_list1 = [sample[1]]
  index_list2 = [sample[2]]

  index_list1 = permutate(index_list1, permutations: options[:mismatches_max])
  index_list2 = permutate(index_list2, permutations: options[:mismatches_max])

  raise "Permutated list sizes differ: #{index_list1.size} != #{index_list2.size}" if index_list1.size != index_list2.size

  index_list1.product(index_list2).each do |index1, index2|
    index_hash[hash_index("#{index1}#{index2}")] = i
  end

  file_forward = "#{sample[0]}#{suffix1}"
  file_reverse = "#{sample[0]}#{suffix2}"
  io_forward   = BioPieces::Fastq.open(File.join(options[:output_dir], file_forward), 'w', compress: options[:compress])
  io_reverse   = BioPieces::Fastq.open(File.join(options[:output_dir], file_reverse), 'w', compress: options[:compress])
  file_hash[i] = [io_forward, io_reverse]
end

undetermined = samples.size + 1

file_forward = "Undetermined#{suffix1}"
file_reverse = "Undetermined#{suffix2}"
io_forward   = BioPieces::Fastq.open(File.join(options[:output_dir], file_forward), 'w', compress: options[:compress])
io_reverse   = BioPieces::Fastq.open(File.join(options[:output_dir], file_reverse), 'w', compress: options[:compress])
file_hash[undetermined] = [io_forward, io_reverse]
 
stats = {
  count:           0,
  match:           0,
  undetermined:    0,
  index1_bad_mean: 0,
  index2_bad_mean: 0,
  index1_bad_min:  0,
  index2_bad_min:  0
}

miss_hash = {
  forward: Hash.new(0),
  reverse: Hash.new(0)
}

time_start = Time.now

begin
  i1_io = BioPieces::Fastq.open(index1_file)
  i2_io = BioPieces::Fastq.open(index2_file)
  r1_io = BioPieces::Fastq.open(read1_file)
  r2_io = BioPieces::Fastq.open(read2_file)

  print "\e[H\e[2J" if options[:verbose] # Console code to clear screen

  while i1 = i1_io.get_entry and i2 = i2_io.get_entry and r1 = r1_io.get_entry and r2 = r2_io.get_entry
    if i1.scores_mean < options[:scores_mean]
      stats[:index1_bad_mean] += 2
      stats[:undetermined] += 2
      io_forward, io_reverse = file_hash[undetermined]
    elsif i2.scores_mean < options[:scores_mean]
      stats[:index2_bad_mean] += 2
      stats[:undetermined] += 2
      io_forward, io_reverse = file_hash[undetermined]
    elsif i1.scores_min < options[:scores_min]
      stats[:index1_bad_min] += 2
      stats[:undetermined] += 2
      io_forward, io_reverse = file_hash[undetermined]
    elsif i2.scores_min < options[:scores_min]
      stats[:index2_bad_min] += 2
      stats[:undetermined] += 2
      io_forward, io_reverse = file_hash[undetermined]
    elsif sample_id = index_hash[hash_index("#{i1.seq}#{i2.seq}")]
      stats[:match] += 2
      io_forward, io_reverse = file_hash[sample_id]
    else
      stats[:undetermined] += 2
      io_forward, io_reverse = file_hash[undetermined]

      miss_hash[:forward][i1.seq] += 1
      miss_hash[:reverse][i2.seq] += 1
    end

    io_forward.puts r1.to_fastq
    io_reverse.puts r2.to_fastq

    stats[:count] += 2

    if options[:verbose] and (stats[:count] % 1_000) == 0
      print "\e[1;1H"    # Console code to move cursor to 1,1 coordinate.
      stats[:time] = (Time.mktime(0) + (Time.now - time_start)).strftime("%H:%M:%S")
      pp stats
    end

    break if stats[:count] == 10_000
  end
ensure
  i1_io.close
  i2_io.close
  r1_io.close
  r2_io.close
end

pp stats if options[:verbose]

samples.each do |sample|
  miss_hash[:forward].delete sample[1]
  miss_hash[:reverse].delete sample[2]
end

File.open(File.join(options[:output_dir], "Undetermined_forward.tsv"), 'w') do |ios|
  miss_hash[:forward].sort_by { |index, count| -1 * count }.each { |index, count| ios.puts "#{count}\t#{index}" }
end

File.open(File.join(options[:output_dir], "Undetermined_reverse.tsv"), 'w') do |ios|
  miss_hash[:reverse].sort_by { |index, count| -1 * count }.each { |index, count| ios.puts "#{count}\t#{index}" }
end

at_exit { file_hash.each_value { |value| value[0].close; value[1].close } }
