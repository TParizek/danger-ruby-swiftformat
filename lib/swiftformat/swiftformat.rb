require "logger"
require "pathname"

module Danger
  class SwiftFormat
    def initialize(path = nil)
      @path = path || "swiftformat"
      @project_root = nil
    end

    def installed?
      Cmd.run([@path, "--version"])
    end

    def check_format(files, additional_args = "", swiftversion = "")
      @repo_root = `git rev-parse --show-toplevel`.strip
      @current_dir = Dir.pwd

      repo_root_path = Pathname.new(@repo_root)
      current_dir_path = Pathname.new(@current_dir)

      # Danger's git file paths are typically repo-root-relative, even when Danger runs
      # from a subdirectory. SwiftFormat is executed in the current working directory,
      # so we convert repo-root-relative paths into paths relative to the current dir.
      adjusted_files = files.map { |file| adjust_file_path(file, repo_root_path, current_dir_path) }

      cmd = [@path] + adjusted_files
      cmd << additional_args.split unless additional_args.nil? || additional_args.empty?

      unless swiftversion.nil? || swiftversion.empty?
        cmd << "--swiftversion"
        cmd << swiftversion
      end

      cmd << %w(--lint --lenient)
      stdout, stderr, status = Cmd.run(cmd.flatten)

      output = stdout.empty? ? stderr : stdout
      raise "Error running SwiftFormat: Empty output." unless output

      output = output.strip.no_color

      if status && !status.success?
        raise "Error running SwiftFormat:\nError: #{output}"
      else
        raise "Error running SwiftFormat: Empty output." if output.empty?
      end

      process(output)
    end

    private

    def adjust_file_path(file, repo_root_path, current_dir_path)
      return file if file.nil?

      # Keep explicit "current directory" target stable (used in specs and supported by swiftformat).
      return file if file == "." || file == "./"

      file_path = Pathname.new(file)
      return file if file_path.absolute?

      # Convert repo-root-relative file/directory paths into paths relative to current working dir.
      absolute = repo_root_path.join(file_path).cleanpath
      absolute.relative_path_from(current_dir_path).to_s
    end

    def process(output)
      {
          errors: errors(output),
          stats: {
              run_time: run_time(output)
          }
      }
    end

    ERRORS_REGEX = /(.*:\d+:\d+): ((warning|error):.*)$/.freeze

    def errors(output)
      errors = []
      output.scan(ERRORS_REGEX) do |match|
        next if match.count < 2

        file_path_with_coords = match[0]
        parts = file_path_with_coords.match(/^(.+):(\d+):(\d+)$/)
        if parts
          file_path_only = parts[1]
          line_num = parts[2]
          col_num = parts[3]
        else
          file_path_only = file_path_with_coords
          line_num = nil
          col_num = nil
        end

        if File.absolute_path?(file_path_only)
          relative_path = file_path_only

          if @repo_root
            begin
              relative_path = Pathname.new(file_path_only).relative_path_from(Pathname.new(@repo_root)).to_s
            rescue StandardError
              # Unable to convert to relative path
            end
          end

          if line_num && col_num
            file_path_with_coords = "#{relative_path}:#{line_num}:#{col_num}"
          else
            file_path_with_coords = relative_path
          end
        end

        errors << {
            file: file_path_with_coords,
            rules: match[1].split(",").map(&:strip)
        }
      end
      errors
    end

    RUNTIME_REGEX = /.*SwiftFormat completed.*(.+\..+)s/.freeze

    def run_time(output)
      if RUNTIME_REGEX.match(output)
        RUNTIME_REGEX.match(output)[1]
      else
        logger = Logger.new($stderr)
        logger.error("Invalid run_time output: #{output}")
        "-1"
      end
    end
  end
end
