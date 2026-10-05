require_relative "../test_helper"
require_relative "../support/source_snapshot"

class AliasProducerTest < Minitest::Test
  include SourceSnapshot

  def resolved_calls(source, base = direct_job)
    Jobcompat::Engine.new(source_snapshot(base, "base"), source_snapshot(source)).calls["head"]
  end

  def test_every_class_object_producer_normalizes_to_terminal
    source = direct_job + "OldJob = MiddleJob\nMiddleJob = NewJob\n" + <<~RUBY
      OldJob.perform_async(1)
      OldJob.perform_in(10, 1)
      OldJob.perform_at(time, 1)
      OldJob.perform_bulk([[1], [2]])
      OldJob.set(queue: :critical).perform_async(1)
      OldJob.set(queue: :critical).perform_in(10, 1)
      OldJob.set(queue: :critical).perform_at(time, 1)
      OldJob.set(queue: :critical).perform_bulk([[1]])
      Sidekiq::Client.push("class" => OldJob, "args" => [1])
      Sidekiq::Client.push_bulk("class" => OldJob, "args" => [[1]])
    RUBY
    calls = resolved_calls(source)
    assert_equal 10, calls.length
    calls.each do |call|
      assert_equal ["NewJob", "OldJob", true, 1, nil], call.values_at(:worker, :attributed_worker, :identity_known, :arity, :reason)
      assert_equal 6, call[:locations].length
      assert call[:locations].any? { |location| location.role == "consumer" }
    end
  end

  def test_exact_strings_are_not_alias_normalized_or_lexically_prefixed
    source = direct_job + "OldJob = NewJob\nmodule Admin\n" + <<~RUBY
      Sidekiq::Client.push("class" => "OldJob", "args" => [1])
      Sidekiq::Client.push_bulk("class" => "OldJob", "args" => [[1]])
      end
    RUBY
    calls = resolved_calls(source)
    assert_equal ["OldJob", "OldJob"], calls.map { |call| call[:worker] }
    assert calls.all? { |call| call[:identity_known] && call[:reason].nil? }
  end

  def test_identity_known_and_arity_unknown_are_independent
    known = resolved_calls(direct_job + "OldJob = NewJob\nOldJob.perform_async(*args)").first
    assert_equal ["NewJob", true, nil, "splat_arguments"], known.values_at(:worker, :identity_known, :arity, :reason)
    %w[perform_async perform_bulk].each do |method|
      call = resolved_calls("OldJob = choose_job\nOldJob.#{method}(1)").first
      assert_equal [nil, "OldJob", false, "unsupported_alias_assignment"], call.values_at(:worker, :attributed_worker, :identity_known, :reason)
    end
    call = resolved_calls("OldJob = MissingJob\nSidekiq::Client.push('class' => OldJob, 'args' => [1])").first
    assert_nil call[:worker]
    assert_equal "alias_target_unresolved", call[:reason]
  end

  def test_snapshot_local_aliases_do_not_borrow_opposite_revision
    base = direct_job("BaseJob") + "OldJob = BaseJob"
    head = direct_job("HeadJob") + "OldJob = HeadJob\nOldJob.perform_async(1)"
    assert_equal "HeadJob", resolved_calls(head, base).first[:worker]
    call = resolved_calls("OldJob.perform_async(1)", base).first
    refute call[:identity_known]
  end

  def test_alias_lookup_lexical_rooted_and_unsupported_namespace
    source = direct_job + direct_job("Admin::NewJob") + <<~RUBY
      OldJob = NewJob
      module Admin
        OldJob = NewJob
        OldJob.perform_async(1)
        ::OldJob.perform_async(1)
        Sidekiq::Client.push("class" => OldJob, "args" => [1])
      end
    RUBY
    assert_equal ["Admin::NewJob", "NewJob", "Admin::NewJob"], resolved_calls(source).map { |call| call[:worker] }
  end

  def test_client_hash_class_uncertainty_does_not_use_earlier_alias
    source = direct_job + "OldJob = NewJob\nSidekiq::Client.push('class' => OldJob, 'args' => [1], **payload)"
    call = resolved_calls(source).first
    refute call[:identity_known]
    assert_nil call[:worker]
    assert_equal "dynamic_client_class", call[:reason]
  end

  def test_non_alias_cross_revision_lexical_attribution_is_preserved
    source = direct_job + "module Admin; NewJob.perform_async(1); end"
    calls = resolved_calls(source, direct_job("Admin::NewJob"))
    assert_equal "Admin::NewJob", calls.first[:worker]
    assert_nil calls.first[:reason]
  end

  def test_opposite_revision_names_do_not_shadow_local_alias_lookup
    base = direct_job("Admin::OldJob") + direct_job
    head = direct_job + "OldJob = NewJob\nmodule Admin; OldJob.perform_async(1); end"
    call = resolved_calls(head, base).first
    assert_equal ["NewJob", "OldJob", true, nil], call.values_at(:worker, :attributed_worker, :identity_known, :reason)

    base = direct_job("ExistingJob") + "module Admin; OldJob = ::ExistingJob; end"
    head = direct_job("OldJob") + "module Admin; OldJob.perform_async(1); end"
    call = resolved_calls(head, base).first
    assert_equal ["OldJob", "OldJob", true, nil], call.values_at(:worker, :attributed_worker, :identity_known, :reason)
  end

  def test_nearer_non_worker_binding_blocks_farther_alias_for_class_objects
    producers = ["OldJob.perform_async(1, 2)", "OldJob.set(queue: :low).perform_async(1, 2)",
                 "OldJob.perform_bulk([[1, 2]])", "Sidekiq::Client.push('class' => OldJob, 'args' => [1, 2])",
                 "Sidekiq::Client.push_bulk('class' => OldJob, 'args' => [[1, 2]])"]
    ["class", "module"].each do |kind|
      producers.each do |producer|
        source = direct_job + "OldJob = NewJob\nmodule Admin; #{kind} OldJob; end; #{producer}; end"
        call = resolved_calls(source).first
        assert_equal [nil, "Admin::OldJob", false, "worker_not_recognized"],
                     call.values_at(:worker, :attributed_worker, :identity_known, :reason), source
        assert call[:locations].any? { |location| location.role == "worker_declaration" }
      end
    end
    source = direct_job + "OldJob = NewJob\nmodule Admin; class OldJob; end; ::OldJob.perform_async(1); " +
             "Sidekiq::Client.push('class' => 'OldJob', 'args' => [1]); end"
    assert_equal ["NewJob", "OldJob"], resolved_calls(source).map { |call| call[:worker] }
  end
end
