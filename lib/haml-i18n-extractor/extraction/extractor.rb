module Haml
  module I18n
    class Extractor

      def self.debug?
        ENV['DEBUG_EXTRACTOR']
      end

      # helpful for debugging
      def self.extractors
        @extractors ||= []
      end

      class InvalidSyntax < StandardError ; end
      class NotADirectory < StandardError ; end
      class NotDefinedLineType < StandardError ; end
      class AbortFile < StandardError ; end

      LINE_TYPES_ALL = [:plain, :script, :silent_script, :haml_comment, :tag, :comment, :doctype, :filter, :root]
      LINE_TYPES_ADD_EVAL = [:plain, :tag]

      attr_reader :haml_reader, :haml_writer
      attr_reader :locale_hash, :yaml_writer, :type
      attr_reader :current_line

      DEFAULT_LINE_LOCALE_HASH = { :modified_line => nil,:keyname => nil,:replaced_text => nil, :path => nil }

      def initialize(haml_path, opts = {})
        @options = opts
        @type = @options[:type]
        @interactive = @options[:interactive]
        @prompter = Haml::I18n::Extractor::Prompter.new
        @haml_reader = Haml::I18n::Extractor::HamlReader.new(haml_path)
        validate_haml(@haml_reader.body)
        @haml_writer = Haml::I18n::Extractor::HamlWriter.new(haml_path, {:type => @type})
        @yaml_writer = Haml::I18n::Extractor::YamlWriter.new(@options[:i18n_scope], @options[:yaml_file])
        @tagging_writer ||= Haml::I18n::Extractor::TaggingWriter.new
        # hold all the processed lines
        @body = []
        # holds a line_no => {info_about_line_replacemnts_or_not}
        @locale_hash = {}

        self.class.extractors << self
      end

      def run
        assign_replacements
        validate_haml(@haml_writer.body)
        @yaml_writer.write_file
        @haml_writer.write_file
      end

      def assign_new_body
        @haml_writer.body = new_body
      end

      def assign_yaml
        @yaml_writer.locale_hash = @locale_hash
      end

      def assign_replacements
        assign_new_body
        assign_yaml
      end

      def new_body
        begin
          @current_line = 1
          @haml_reader.lines.each do |orig_line|
            process_line(orig_line, @current_line)
            @current_line += 1
          end
        rescue AbortFile
          @prompter.moving_to_next_file
          add_rest_of_file_to_body(@current_line)
        end
        @body.join("\n") + "\n"
      end

      # this is the bulk of it:
      # where we end up setting body info and locale_hash.
      # not _write_, just set that info in memory in correspoding locations.
      # refactor more?
      def process_line(orig_line, line_no)
        orig_line.chomp!
        orig_line, whitespace = handle_line_whitespace(orig_line)
        finder_result = handle_line_finding(orig_line, line_no)
        line_type = finder_result.type
        line_match = finder_result.match
        should_be_replaced, text_to_replace, line_locale_hash = gather_replacement_info(orig_line, line_match, line_type, line_no)

        user_action = Haml::I18n::Extractor::UserAction.new('y') # default if no prompting: just do it.
        if should_be_replaced
          if interactive?
            user_action = @prompter.ask_user(orig_line,text_to_replace)
          end
        end

        if user_action.tag?
          @tagging_writer.write(line_locale_hash[:path], line_no)
          add_to_body("#{whitespace}#{orig_line}")
        elsif user_action.next?
          raise AbortFile, "stopping to process the rest of the file"
       elsif user_action.replace_line?
          append_to_locale_hash(line_no, line_locale_hash)
          add_to_body("#{whitespace}#{text_to_replace}")
        elsif user_action.no_replace?
          append_to_locale_hash(line_no, DEFAULT_LINE_LOCALE_HASH)
          add_to_body("#{whitespace}#{orig_line}")
        end

        return should_be_replaced
      end

      def interactive?
        !!@interactive
      end

      private

      def add_rest_of_file_to_body(line_no)
        @haml_reader.lines[line_no-1..@haml_reader.lines.size-1].map do |orig_ln|
          add_to_body(orig_ln.chomp)
        end
      end

      def gather_replacement_info(orig_line, line_match, line_type, line_no)
        if line_match && !line_match.empty?
          replacer = Haml::I18n::Extractor::TextReplacer.new(orig_line, line_match, line_type, line_metadata(line_no))
          hash = replacer.replace_hash.dup.merge!({:path => @haml_reader.path })
          [ true, hash[:modified_line], hash ]
        else
          hash = DEFAULT_LINE_LOCALE_HASH
          [ false, orig_line, hash ]
        end
      end

      def append_to_locale_hash(line_no, hash)
        @locale_hash[line_no] = hash
      end

      def handle_line_finding(orig_line,lineno)
        Haml::I18n::Extractor::TextFinder.new(orig_line,line_metadata(lineno)).process_by_regex
      end

      def line_metadata(lineno)
        @haml_reader.metadata[lineno]
      end

      def handle_line_whitespace(orig_line)
        orig_line.rstrip.match(/([ \t]+)?(.*)/)
        whitespace_indentation = $1
        orig_line = $2
        [ orig_line, whitespace_indentation ]
      end

      def add_to_body(ln)
        @body << ln
      end

      def validate_haml(haml)
        parser = Haml::Parser.new(haml, Haml::Options.new)
        parser.parse
      rescue Haml::SyntaxError
        raise InvalidSyntax, "invalid syntax for haml #{@haml_reader.path}"
      end

    end
  end
end
