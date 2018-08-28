require 'sablon/document_object_model/model'
require 'sablon/processor/document'
require 'sablon/processor/section_properties'

module Sablon
  # Creates a template from an MS Word doc that can be easily manipulated
  class Template
    attr_reader :document

    class << self
      # Adds a new processor to the processors hash. The +pattern+ is used
      # to select which files the processor should handle. Multiple processors
      # can be added for the same pattern.
      def register_processor(pattern, klass, replace_all: false)
        processors[pattern] = [] if replace_all
        #
        if processors[pattern].empty?
          processors[pattern] = [klass]
        else
          processors[pattern] << klass
        end
      end

      # Returns the processor classes with a pattern matching the
      # entry name. If none match nil is returned.
      def get_processors(entry_name)
        key = processors.keys.detect { |pattern| entry_name =~ pattern }
        processors[key]
      end

      def processors
        @processors ||= Hash.new([])
      end
    end

    def initialize(path)
      @path = path
    end

    # Same as +render_to_string+ but writes the processed template to +output_path+.
    def render_to_file(output_path, context, properties = {})
      File.open(output_path, 'wb') do |f|
        f.write render_to_string(context, properties)
      end
    end

    # Process the template. The +context+ hash will be available in the template.
    def render_to_string(context, properties = {})
      render(context, properties).string
    end

    private

    def render(context, properties = {})
      # If just one hash is given, make an one-element array out of it.
      unless context.kind_of?(Array)
        context = [context]
      end

      # initialize DOM
      @document = Sablon::DOM::Model.new(Zip::File.open(@path))
      
      # Copy original template document.
      word_doc = @document.zip_contents["word/document.xml"]
      orig_content = word_doc.dup
      
      # Process whole docx with first (or only) context.
      env = Sablon::Environment.new(self, context.shift)
      env.section_properties = properties
      process(env)

      # Process document.xml for further context hashs.
      @document.current_entry = "word/document.xml"
      context.each do |curr_context|
        # Duplicate document.xml.
        curr_content = orig_content.dup
        
        # Process document.xml under current context.
        env = Sablon::Environment.new(self, curr_context)
        env.section_properties = properties
        process_document(curr_content, env)

        # Append current document body to word_doc.        
        move_section_to_last_paragraph(word_doc)
        curr_children = curr_content.at_xpath(".//w:body").children
        word_doc.at_xpath(".//w:body") << curr_children
      end
      
      # Repair some weird issues.
      repair_document(word_doc)

      Zip::OutputStream.write_buffer(StringIO.new) do |out|
        generate_output_file(out, @document.zip_contents)
      end
    end
    
    # Move the sectPr Node from body to the last paragraph.
    # Then, further nodes and another sectPr can be added.
    # See also http://officeopenxml.com/WPsection.php.
    def move_section_to_last_paragraph(word_doc)
      body = word_doc.at_xpath(".//w:body")
      sec=body.at_xpath("./w:sectPr")
      sec.remove
      secpar = Nokogiri::XML::Node.new("w:p", word_doc) do |node|
        node << Nokogiri::XML::Node.new("w:pPr", word_doc) do |wpr|
          wpr << sec
        end
      end
      body << secpar
    end
    
    # Repair some possible issues of the XML file.
    def repair_document(word_doc)
      # In Libre Office files we observed a missing "r:".
      ["header", "footer"].each do |refs|
        word_doc.xpath(".//w:#{refs}Reference").each do |ref|
          ref_id = ref.attributes["id"]
          if ref_id
            ref.remove_attribute("id")
            ref["r:id"] = ref_id
          end
        end
      end
    end

    # Processes all of the entries searching for ones that match the pattern.
    # The hash is converted into an array first to avoid any possible
    # modification during iteration errors (i.e. creation of a new rels file).
    def process(env)
      @document.zip_contents.to_a.each do |(entry_name, content)|
        @document.current_entry = entry_name
        processors = Template.get_processors(entry_name)
        processors.each { |processor| processor.process(content, env) }
      end
    end
    
    # Process document.xml only. Content is provided as parameter.
    def process_document(content, env)
      processors = Template.get_processors("word/document.xml")
      processors.each { |processor| processor.process(content, env) }
    end

    # IMPORTANT: Open Office does not ignore whitespace around tags.
    # We need to render the xml without indent and whitespace.
    def generate_output_file(zip_out, contents)
      # output entries to zip file
      created_dirs = []
      contents.each do |entry_name, content|
        create_dirs_in_zipfile(created_dirs, File.dirname(entry_name), zip_out)
        zip_out.put_next_entry(entry_name)
        #
        # convert Nokogiri XML to string
        if content.instance_of? Nokogiri::XML::Document
          content = content.to_xml(indent: 0, save_with: 0)
        end
        #
        zip_out.write(content)
      end
    end

    # creates directories of the unzipped docx file in the newly created
    # docx file e.g. in case of word/_rels/document.xml.rels it creates
    # word/ and _rels directories to apply recursive zipping. This is a
    # hack to fix the issue of getting a corrupted file when any referencing
    # between the xml files happen like in the case of implementing hyperlinks.
    # The created_dirs array is augmented in place using '<<'
    def create_dirs_in_zipfile(created_dirs, entry_path, output_stream)
      entry_path_tokens = entry_path.split('/')
      return created_dirs unless entry_path_tokens.length > 1
      #
      prev_dir = ''
      entry_path_tokens.each do |dir_name|
        prev_dir += dir_name + '/'
        next if created_dirs.include? prev_dir
        #
        output_stream.put_next_entry(prev_dir)
        created_dirs << prev_dir
      end
    end
  end

  # Register the standard processors
  Template.register_processor(%r{word/document.xml}, Sablon::Processor::Document)
  Template.register_processor(%r{word/document.xml}, Sablon::Processor::SectionProperties)
  Template.register_processor(%r{word/(?:header|footer)\d*\.xml}, Sablon::Processor::Document)
end
