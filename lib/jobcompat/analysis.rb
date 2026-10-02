require "prism"
require_relative "canonical_worker_name"

module Jobcompat
  Location = Data.define(:revision, :path, :line, :column, :role, :excerpt) do
    def as_json
      {revision: revision, path: path, line: line, column: column, role: role}
    end
  end
  Contract = Data.define(:name, :min_arity, :max_arity, :signature_kind, :signature, :unknown_reason, :locations, :declaration_locations, :fingerprint_parts) do
    def known? = unknown_reason.nil?
    def accepts?(arity) = known? && arity >= min_arity && (max_arity.nil? || arity <= max_arity)
    def superset_of?(other)
      known? && other.known? && min_arity <= other.min_arity && (max_arity.nil? || (!other.max_arity.nil? && other.max_arity <= max_arity))
    end
    def display_range = max_arity.nil? ? "#{min_arity}..∞" : (min_arity == max_arity ? min_arity.to_s : "#{min_arity}..#{max_arity}")
    def as_json
      {status: known? ? "known" : "unknown", min_arity: min_arity, max_arity: max_arity, variadic: known? ? max_arity.nil? : nil,
       signature_kind: signature_kind, signature: signature, unknown_reason: unknown_reason}
    end
  end
  Call = Data.define(:revision, :path, :location, :receiver, :resolution_mode, :root, :namespace, :scope, :method, :arity, :unknown_reason, :fingerprint_parts)
  Unknown = Data.define(:revision, :kind, :reason, :worker, :locations, :fingerprint_parts)
  Fragment = Data.define(:name, :declaration, :includes, :include_tokens, :performs, :lexical_scope)

  class DefinedConstantIndex
    BUDGET = 67_108_864
    attr_reader :selected, :outside, :ambiguous, :unverified

    def initialize
      @selected = Hash.new { |hash, key| hash[key] = [] }
      @outside = Hash.new { |hash, key| hash[key] = [] }
      @ambiguous = []
      @unverified = {}
    end

    def add(name, location, selected:, ambiguous: false)
      if ambiguous
        @ambiguous << [name.split("::").last, location]
      else
        (selected ? @selected : @outside)[name] << location
      end
    end

    def status(name, recognized: false)
      return "recognized_worker" if recognized
      return "defined_unrecognized" unless selected.fetch(name, []).empty?
      return "outside_scan_scope" unless outside.fetch(name, []).empty?
      return "unverified" if unverified[name] || ambiguous.any? { |leaf, _| leaf == name.split("::").last }
      "absent"
    end

    def locations(name)
      selected.fetch(name, []) + outside.fetch(name, []) + ambiguous.filter_map { |leaf, location| location if leaf == name.split("::").last } + [unverified[name]].compact
    end
  end

  class RevisionSnapshot
    attr_reader :label, :ref, :sha, :workers, :calls, :unknowns, :index, :files_scanned, :tracked_ruby

    def initialize(label:, ref:, sha:, workers:, calls:, unknowns:, index:, files_scanned:, tracked_ruby:)
      @label, @ref, @sha, @workers, @calls, @unknowns, @index, @files_scanned, @tracked_ruby = label, ref, sha, workers, calls, unknowns, index, files_scanned, tracked_ruby
    end

    def check_presence(names, repository, config)
      unresolved = names.reject { |name| index.status(name, recognized: workers.key?(name)) != "absent" }
      return if unresolved.empty?
      consumed = 0
      eligible = []
      budget_boundary = nil
      tracked_ruby.reject { |entry| config.scan?(entry.path) }.each do |entry|
        if consumed + entry.size > DefinedConstantIndex::BUDGET
          budget_boundary = entry
          break
        end
        consumed += entry.size
        eligible << entry
      end
      repository.each_blob(eligible) do |entry, bytes|
        candidates = unresolved.select do |name|
          leaf = name.split("::").last
          !leaf.ascii_only? || bytes.b.include?(leaf.b)
        end
        next if candidates.empty?
        begin
          Analyzer.new(label, entry.path, bytes, index: index, presence_only: true).analyze
        rescue Error
          candidates.each { |name| index.unverified[name] = Location.new(label, entry.path, 1, 1, "worker_declaration", nil) }
        end
        unresolved.reject! { |name| !index.outside.fetch(name, []).empty? }
        :stop if unresolved.empty?
      end
      if budget_boundary
        unresolved.each do |name|
          index.unverified[name] ||= Location.new(label, budget_boundary.path, 1, 1, "worker_declaration", nil)
        end
      end
    end
  end

  class Analyzer
    SIMPLE_CONSTANT_BINDINGS = [Prism::ConstantWriteNode, Prism::ConstantOrWriteNode,
                                Prism::ConstantAndWriteNode, Prism::ConstantOperatorWriteNode,
                                Prism::ConstantTargetNode].freeze
    PATH_CONSTANT_BINDINGS = [Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode,
                              Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode,
                              Prism::ConstantPathTargetNode].freeze
    attr_reader :fragments, :calls, :unknowns

    def initialize(revision, path, source, index:, presence_only: false)
      @revision, @path, @source, @index, @presence_only = revision, path, source, index, presence_only
      @fragments, @calls, @unknowns = [], [], []
    end

    def analyze
      result = Prism.parse(@source, filepath: @path)
      @source_encoding = result.source.encoding
      unless result.errors.empty?
        diagnostics = result.errors.map do |error|
          {category: "parse_error", message: "#{@path}:#{error.location.start_line}:#{error.message}",
           location: diagnostic_location(error.location.start_line, error.location.start_column + 1)}
        end
        raise Error.new(diagnostics.first[:message], category: "parse_error", location: diagnostics.first[:location], diagnostics: diagnostics)
      end
      walk(result.value, [], [], nil)
      self
    end

    def self.constant(node)
      node = unwrap_parentheses(node)
      case node
      when Prism::ConstantReadNode then [[node.name.to_s.encode(Encoding::UTF_8)], false]
      when Prism::ConstantPathNode, Prism::ConstantPathTargetNode
        if node.parent.nil?
          [[node.name.to_s.encode(Encoding::UTF_8)], true]
        else
          parent = constant(node.parent)
          parent && [parent[0] + [node.name.to_s.encode(Encoding::UTF_8)], parent[1]]
        end
      end
    end

    def self.unwrap_parentheses(node)
      while node.is_a?(Prism::ParenthesesNode) && node.body.is_a?(Prism::StatementsNode) && node.body.body.one?
        node = node.body.body.first
      end
      node
    end

    def self.normalize(source)
      Prism.lex(source).value.filter_map do |pair|
        token = pair.first
        [token.type, token.value] unless %i[COMMENT EOF IGNORED_NEWLINE NEWLINE].include?(token.type)
      end
    end

    private

    def walk(node, namespace, scope, statement)
      return unless node.is_a?(Prism::Node)
      case node
      when Prism::StatementsNode
        node.body.each { |child| walk(child, namespace, scope, child) }
      when Prism::ClassNode, Prism::ModuleNode
        constant = self.class.constant(node.constant_path)
        name, valid = declaration_name(constant, namespace)
        location = loc(node, "worker_declaration")
        @index.add(name, location, selected: !@presence_only, ambiguous: !valid) if name
        if !name && node.constant_path.is_a?(Prism::ConstantPathNode)
          @index.add(node.constant_path.name.to_s.encode(Encoding::UTF_8), location, selected: !@presence_only, ambiguous: true)
        end
        new_scope = scope + [name || "<unsupported_class>"]
        if node.is_a?(Prism::ClassNode) && valid && !@presence_only
          body = node.body.is_a?(Prism::StatementsNode) ? node.body.body : []
          include_nodes = body.select { |child| sidekiq_include?(child) }
          includes = include_nodes.map { |child| loc(child, "worker_declaration") }
          performs = body.select { |child| child.is_a?(Prism::DefNode) && child.receiver.nil? && child.name == :perform }
          @fragments << Fragment.new(name, location, includes, include_nodes.map { |child| self.class.normalize(child.location.slice) },
                                     performs.map { |perform| [perform, loc(perform, "consumer"), signature(perform)] }, new_scope)
        elsif node.is_a?(Prism::ClassNode) && !valid && !@presence_only && node.body.is_a?(Prism::StatementsNode) && node.body.body.any? { |child| sidekiq_include?(child) }
          include_nodes = node.body.body.select { |child| sidekiq_include?(child) }
          include_tokens = include_nodes.map { |child| self.class.normalize(child.location.slice) }.sort_by(&:inspect)
          @unknowns << Unknown.new(@revision, "worker_identity", "unsupported_constant_path", nil,
                                   [location] + include_nodes.map { |child| loc(child, "worker_declaration") },
                                   [@path, new_scope, self.class.normalize(node.constant_path.location.slice), include_tokens])
        end
        child_namespace = valid && namespace ? namespace + [name] : nil
        walk(node.superclass, namespace, scope, statement) if node.is_a?(Prism::ClassNode) && node.superclass
        walk(node.body, child_namespace, new_scope, nil) if node.body
      when Prism::DefNode
        method_scope = node.receiver ? [self.class.normalize(node.receiver.location.slice), node.name.to_s] : node.name.to_s
        child_scope = scope + [method_scope]
        walk(node.receiver, namespace, scope, statement) if node.receiver
        walk(node.parameters, namespace, child_scope, node.parameters) if node.parameters
        walk(node.body, namespace, child_scope, nil) if node.body
      when Prism::SingletonClassNode
        walk(node.expression, namespace, scope, statement)
        singleton_scope = scope + [["singleton_class", self.class.normalize(node.expression.location.slice)]]
        walk(node.body, namespace, singleton_scope, nil) if node.body
      when Prism::CallNode
        extract_call(node, namespace, scope, statement) unless @presence_only
        node.compact_child_nodes.each { |child| walk(child, namespace, scope, statement) }
      else
        constant_write(node, namespace) if SIMPLE_CONSTANT_BINDINGS.any? { |type| node.is_a?(type) } || PATH_CONSTANT_BINDINGS.any? { |type| node.is_a?(type) }
        node.compact_child_nodes.each { |child| walk(child, namespace, scope, statement) }
      end
    end

    def declaration_name(constant, namespace)
      return [nil, false] unless constant
      segments, rooted = constant
      return [segments.join("::"), false] if namespace.nil? && !rooted
      return [segments.join("::"), false] if segments.length > 1 && !rooted && !namespace.empty?
      [((rooted || segments.length > 1) ? segments : (namespace.empty? ? [] : namespace.last.split("::")) + segments).join("::"), true]
    end

    def constant_write(node, namespace)
      if SIMPLE_CONSTANT_BINDINGS.any? { |type| node.is_a?(type) }
        prefix = namespace.nil? || namespace.empty? ? [] : namespace.last.split("::")
        @index.add((prefix + [node.name.to_s.encode(Encoding::UTF_8)]).join("::"), loc(node, "worker_declaration"),
                   selected: !@presence_only, ambiguous: namespace.nil?)
      else
        target = node.is_a?(Prism::ConstantPathTargetNode) ? node : node.target
        constant = self.class.constant(target)
        name, valid = declaration_name(constant, namespace)
        @index.add(name, loc(node, "worker_declaration"), selected: !@presence_only, ambiguous: !valid) if name
        if !name && (target.is_a?(Prism::ConstantPathNode) || target.is_a?(Prism::ConstantPathTargetNode))
          @index.add(target.name.to_s.encode(Encoding::UTF_8), loc(node, "worker_declaration"), selected: !@presence_only, ambiguous: true)
        end
      end
    end

    def sidekiq_include?(node)
      return false unless node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :include
      (node.arguments&.arguments || []).any? do |arg|
        constant = self.class.constant(arg)
        constant && %w[Sidekiq::Job Sidekiq::Worker].include?(constant[0].join("::"))
      end
    end

    def signature(node)
      finish = node.rparen_loc ? node.rparen_loc.end_offset : (node.parameters ? node.parameters.location.end_offset : node.name_loc.end_offset)
      header = @source.byteslice(node.location.start_offset...finish).to_s.force_encoding(@source_encoding).strip
      header.gsub(/\Adef\s+/, "").encode(Encoding::UTF_8)
    end

    def extract_call(node, namespace, scope, statement)
      method = node.name.to_s
      if %w[push push_bulk].include?(method) && sidekiq_client?(node.receiver)
        extract_client_call(node, namespace, scope, statement, method)
        return
      end
      return unless %w[perform_async perform_in perform_at perform_bulk].include?(method)
      receiver = self.class.unwrap_parentheses(node.receiver)
      set_call = receiver if receiver.is_a?(Prism::CallNode) && receiver.name == :set
      receiver = set_call.receiver if set_call
      constant = self.class.constant(receiver)
      safe = node.call_operator_loc&.slice == "&." || set_call&.call_operator_loc&.slice == "&."
      arguments = node.arguments&.arguments || []
      if method == "perform_bulk"
        extract_worker_bulk(node, namespace, scope, statement, method, receiver, constant, safe, arguments)
        return
      end
      reason = if arguments.any? { |arg| arg.is_a?(Prism::SplatNode) }
                 "splat_arguments"
               elsif arguments.any? { |arg| arg.is_a?(Prism::ForwardingArgumentsNode) }
                 "forwarded_arguments"
               elsif method != "perform_async" && arguments.empty?
                 "missing_schedule_argument"
               elsif constant.nil? && !receiver.is_a?(Prism::ConstantPathNode)
                 "dynamic_receiver"
               elsif constant.nil?
                 "unsupported_constant_path"
               elsif safe
                 "safe_navigation_receiver"
               end
      arity = reason && %w[splat_arguments forwarded_arguments missing_schedule_argument].include?(reason) ? nil : arguments.length - (method == "perform_async" ? 0 : 1)
      emit_call(node, namespace, scope, statement, method, constant&.first&.join("::"), "lexical_constant", constant&.last, arity, reason)
    end

    def extract_worker_bulk(node, namespace, scope, statement, method, receiver_node, constant, safe, arguments)
      reason = if safe
                 "safe_navigation_receiver"
               elsif constant.nil? && !receiver_node.is_a?(Prism::ConstantPathNode)
                 "dynamic_receiver"
               elsif constant.nil?
                 "unsupported_constant_path"
               elsif arguments.empty?
                 "dynamic_bulk_arguments"
               elsif arguments.drop(1).any? { |arg| !arg.is_a?(Prism::KeywordHashNode) || arg.elements.any? { |element| element.is_a?(Prism::AssocSplatNode) } }
                 "dynamic_bulk_options"
               end
      receiver = constant&.first&.join("::")
      if reason
        emit_call(node, namespace, scope, statement, method, receiver, "lexical_constant", constant&.last, nil, reason)
        return
      end
      arities, unknown = extract_bulk_arities(arguments.first)
      arities.each do |arity|
        emit_call(node, namespace, scope, statement, method, receiver, "lexical_constant", constant.last, arity, nil)
      end
      if unknown
        emit_call(node, namespace, scope, statement, method, receiver, "lexical_constant", constant.last, nil, "dynamic_bulk_arguments")
      end
    end

    def extract_client_call(node, namespace, scope, statement, method)
      if node.call_operator_loc&.slice == "&."
        emit_call(node, namespace, scope, statement, method, nil, nil, nil, nil, "safe_navigation_receiver")
        return
      end
      arguments = node.arguments&.arguments || []
      payload = arguments.one? ? self.class.unwrap_parentheses(arguments.first) : nil
      unless payload.is_a?(Prism::HashNode) || payload.is_a?(Prism::KeywordHashNode)
        emit_call(node, namespace, scope, statement, method, nil, nil, nil, nil, "dynamic_client_payload")
        return
      end
      associations = payload.elements.select { |element| element.is_a?(Prism::AssocNode) }
      class_node, class_status = client_hash_value(payload.elements, "class")
      args_node, args_status = client_hash_value(payload.elements, "args")
      args_node = self.class.unwrap_parentheses(args_node)
      invalid_keys = associations.any? do |association|
        key = self.class.unwrap_parentheses(association.key)
        next false if key.is_a?(Prism::StringNode)
        next false unless key.static_literal?
        method != "push_bulk" || !key.is_a?(Prism::SymbolNode) || !%w[at batch_size spread_interval].include?(key.unescaped)
      end
      reason = "unsupported_client_payload" if [class_status, args_status].any? { |status| %i[missing unsupported].include?(status) } || invalid_keys
      reason ||= "dynamic_client_class" if class_status == :unknown
      receiver, mode, rooted, class_reason = client_worker(class_node)
      reason ||= class_reason
      reason ||= method == "push" ? "dynamic_client_args" : "dynamic_bulk_arguments" if args_status == :unknown
      if reason
        emit_call(node, namespace, scope, statement, method, receiver, mode, rooted, nil, reason)
        return
      end
      if method == "push"
        unless args_node.is_a?(Prism::ArrayNode) && args_node.elements.none? { |element| element.is_a?(Prism::SplatNode) }
          emit_call(node, namespace, scope, statement, method, receiver, mode, rooted, nil, "dynamic_client_args")
          return
        end
        emit_call(node, namespace, scope, statement, method, receiver, mode, rooted, args_node.elements.length, nil)
      else
        arities, unknown = extract_bulk_arities(args_node)
        arities.each { |arity| emit_call(node, namespace, scope, statement, method, receiver, mode, rooted, arity, nil) }
        if unknown
          emit_call(node, namespace, scope, statement, method, receiver, mode, rooted, nil, "dynamic_bulk_arguments")
        end
      end
    end

    def extract_bulk_arities(node)
      node = self.class.unwrap_parentheses(node)
      return [[], true] unless node.is_a?(Prism::ArrayNode)
      arities = []
      unknown = false
      node.elements.each do |element|
        element = self.class.unwrap_parentheses(element)
        if element.is_a?(Prism::ArrayNode) && element.elements.none? { |item| item.is_a?(Prism::SplatNode) }
          arities << element.elements.length
        else
          unknown = true
        end
      end
      [arities.uniq.sort, unknown]
    end

    def sidekiq_client?(node)
      constant = self.class.constant(node)
      constant && constant.first == %w[Sidekiq Client]
    end

    def client_hash_value(elements, key)
      elements.reverse_each do |element|
        return [nil, :unknown] if element.is_a?(Prism::AssocSplatNode)
        entry_key = self.class.unwrap_parentheses(element.key)
        if entry_key.is_a?(Prism::StringNode)
          return [element.value, :known] if entry_key.unescaped == key
        elsif !entry_key.static_literal?
          return [nil, :unsupported]
        end
      end
      [nil, :missing]
    end

    def client_worker(node)
      node = self.class.unwrap_parentheses(node)
      constant = self.class.constant(node)
      return [constant.first.join("::"), "client_constant", constant.last, nil] if constant
      if node.is_a?(Prism::StringNode)
        name = CanonicalWorkerName.parse(node.unescaped)
        return [name, "exact_string", false, nil] if name
        return [nil, nil, nil, "unsupported_client_payload"]
      end
      [nil, nil, nil, "dynamic_client_class"]
    end

    def emit_call(node, namespace, scope, statement, method, receiver, resolution_mode, root, arity, reason)
      expression = self.class.normalize(node.location.slice)
      enclosing = self.class.normalize((statement || node).location.slice)
      @calls << Call.new(@revision, @path, loc(node, reason ? "unknown_call" : "producer"), receiver, resolution_mode, root,
                         namespace, scope, method, arity, reason, [@path, scope, expression, enclosing])
    end

    def loc(node, role)
      Location.new(@revision, @path, node.location.start_line, node.location.start_column + 1, role, node.location.slice.to_s.lines.first&.strip&.encode(Encoding::UTF_8))
    end

    def diagnostic_location(line, column)
      {revision: @revision, path: @path, line: line, column: column}
    end
  end

  class SnapshotBuilder
    def initialize(repository, config)
      @repository, @config = repository, config
    end

    def build(label, ref, sha)
      entries = @repository.entries(sha)
      selected = entries.select { |entry| @config.scan?(entry.path) }
      tracked = entries.select { |entry| entry.path.end_with?(".rb") }
      index = DefinedConstantIndex.new
      fragments, calls, unknowns, errors = [], [], [], []
      @repository.each_blob(selected) do |entry, bytes|
        path = entry.path
        begin
          result = Analyzer.new(label, path, bytes, index: index).analyze
          fragments.concat(result.fragments)
          calls.concat(result.calls)
          unknowns.concat(result.unknowns)
        rescue Error => error
          errors << error
        end
      end
      unless errors.empty?
        diagnostics = errors.flat_map do |error|
          error.diagnostics || [{category: error.category, message: error.message, location: error.location}]
        end.sort_by { |item| [item[:location]&.fetch(:revision, ""), item[:location]&.fetch(:path, ""), item[:location]&.fetch(:line, 0), item[:location]&.fetch(:column, 0), item[:message]] }
        raise Error.new(diagnostics.first[:message], category: "parse_error", location: diagnostics.first[:location], diagnostics: diagnostics)
      end
      workers = {}
      fragments.group_by(&:name).sort.each do |name, group|
        next if group.flat_map(&:includes).empty?
        relevant = group.select { |fragment| !fragment.includes.empty? || !fragment.performs.empty? }
        declarations = relevant.map(&:declaration).sort_by { |loc| [loc.path, loc.line, loc.column] }
        performs = group.flat_map(&:performs).sort_by { |entry| [entry[1].path, entry[1].line, entry[1].column] }
        includes = group.flat_map(&:includes)
        locations = (declarations + includes + performs.map { |entry| entry[1] }).uniq.sort_by { |loc| [loc.path, loc.line, loc.column, loc.role] }
        fingerprint_parts = [relevant.map { |fragment| [fragment.declaration.path, fragment.lexical_scope] }.sort_by(&:inspect),
                             relevant.flat_map(&:include_tokens).sort_by(&:inspect),
                             performs.map { |entry| Analyzer.normalize(entry.last) }.sort_by(&:inspect)]
        if performs.length != 1
          reason = performs.empty? ? "missing_perform" : "multiple_perform_definitions"
          signatures = performs.map(&:last).sort.join(" | ")
          workers[name] = Contract.new(name, nil, nil, nil, signatures.empty? ? nil : signatures, reason, locations, declarations, fingerprint_parts)
          next
        end
        node, _, signature = performs.first
        params = node.parameters
        reason = params && (!params.keywords.empty? || (params.keyword_rest && !params.keyword_rest.is_a?(Prism::ForwardingParameterNode))) ? "keyword_parameters" : nil
        reason ||= "unsupported_parameters" if params && !(params.is_a?(Prism::ParametersNode))
        if reason
          workers[name] = Contract.new(name, nil, nil, nil, signature, reason, locations, declarations, fingerprint_parts)
        else
          required = params ? params.requireds.length + params.posts.length : 0
          optional = params ? params.optionals.length : 0
          forwarding = params && params.keyword_rest.is_a?(Prism::ForwardingParameterNode)
          rest = params && (params.rest || forwarding)
          workers[name] = Contract.new(name, required, rest ? nil : required + optional, forwarding ? "forwarding" : "positional", signature, nil, locations, declarations, fingerprint_parts)
        end
      end
      RevisionSnapshot.new(label: label, ref: ref, sha: sha, workers: workers, calls: calls, unknowns: unknowns, index: index,
                           files_scanned: selected.length, tracked_ruby: tracked)
    end
  end
end
