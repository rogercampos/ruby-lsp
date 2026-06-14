# typed: true
# frozen_string_literal: true

require "test_helper"

module RubyIndexer
  class IndexCacheTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir
      @cache = IndexCache.new(File.join(@dir, "cache"))
      @uri = URI::Generic.from_path(path: "/fake/gem/lib/foo.rb")
    end

    def teardown
      FileUtils.remove_entry(@dir)
    end

    def test_write_and_read_round_trips_entries
      entries = index_entries(<<~RUBY)
        module Foo
          CONST = 123

          class Bar
            attr_reader :baz

            def qux(a, b = 1, *c, d:, **e, &f)
            end

            private

            def secret; end
          end
        end
      RUBY

      @cache.write("foo-1.0.0", entries)

      # Read from a brand new cache instance pointing at the same directory to ensure nothing is kept in memory
      loaded = IndexCache.new(File.join(@dir, "cache")).read("foo-1.0.0")
      refute_nil(loaded)
      loaded = loaded #: as !nil

      assert_equal(entries.map(&:class), loaded.map(&:class))
      assert_equal(entries.map(&:name), loaded.map(&:name))
      assert_equal(entries.map { |e| e.uri.to_s }, loaded.map { |e| e.uri.to_s })

      entries.zip(loaded).each do |original, copy|
        copy = copy #: as Entry
        original = original #: as Entry

        assert_equal(original.location.start_line, copy.location.start_line)
        assert_equal(original.location.end_line, copy.location.end_line)
        assert_equal(original.location.start_column, copy.location.start_column)
        assert_equal(original.location.end_column, copy.location.end_column)
        assert_equal(original.visibility, copy.visibility)

        next unless original.is_a?(Entry::Member) && copy.is_a?(Entry::Member)

        assert_equal(
          original.signatures.map { |s| s.parameters.map(&:name) },
          copy.signatures.map { |s| s.parameters.map(&:name) },
        )
        assert_equal(
          original.signatures.map { |s| s.parameters.map(&:class) },
          copy.signatures.map { |s| s.parameters.map(&:class) },
        )
      end
    end

    def test_owner_object_identity_is_preserved
      entries = index_entries(<<~RUBY)
        class Bar
          def hello; end
        end
      RUBY

      @cache.write("foo-1.0.0", entries)
      loaded = @cache.read("foo-1.0.0") #: as !nil

      namespace = loaded.find { |e| e.is_a?(Entry::Class) } #: as Entry::Class
      method = loaded.find { |e| e.is_a?(Entry::Method) } #: as Entry::Method

      # Marshalling the whole array in one shot must preserve the shared owner reference
      assert_same(namespace, method.owner)
    end

    def test_read_returns_nil_for_missing_key
      assert_nil(@cache.read("does-not-exist"))
    end

    def test_schema_version_mismatch_is_a_miss
      entries = index_entries("class Bar; end")
      @cache.write("foo-1.0.0", entries)

      # Tamper with the file so that it carries a different schema version
      path = File.join(@dir, "cache", "foo-1.0.0.dump")
      payload = Marshal.load(File.binread(path)) #: as Hash[Symbol, untyped]
      payload[:schema_version] = IndexCache::SCHEMA_VERSION + 1
      File.binwrite(path, Marshal.dump(payload))

      assert_nil(@cache.read("foo-1.0.0"))
    end

    def test_ruby_version_mismatch_is_a_miss
      entries = index_entries("class Bar; end")
      @cache.write("foo-1.0.0", entries)

      path = File.join(@dir, "cache", "foo-1.0.0.dump")
      payload = Marshal.load(File.binread(path)) #: as Hash[Symbol, untyped]
      payload[:ruby_version] = "0.0.0"
      File.binwrite(path, Marshal.dump(payload))

      assert_nil(@cache.read("foo-1.0.0"))
    end

    def test_corrupt_cache_is_a_miss_and_is_deleted
      FileUtils.mkdir_p(File.join(@dir, "cache"))
      path = File.join(@dir, "cache", "foo-1.0.0.dump")
      File.binwrite(path, "this is not a marshal dump")

      capture_io do
        assert_nil(@cache.read("foo-1.0.0"))
      end

      refute_path_exists(path)
    end

    def test_prune_removes_stale_files
      entries = index_entries("class Bar; end")
      @cache.write("foo-1.0.0", entries)
      @cache.write("foo-2.0.0", entries)
      @cache.write("bar-1.0.0", entries)

      @cache.prune!(["foo-2.0.0"])

      cache_dir = File.join(@dir, "cache")
      refute_path_exists(File.join(cache_dir, "foo-1.0.0.dump"))
      assert_path_exists(File.join(cache_dir, "foo-2.0.0.dump"))
      refute_path_exists(File.join(cache_dir, "bar-1.0.0.dump"))
    end

    def test_project_snapshot_round_trips
      entries = index_entries("class Bar\nend\n")
      path = @uri.full_path #: as !nil
      @cache.write_project_snapshot({ path => { fingerprint: [123.0, 45], entries: entries } })

      loaded = IndexCache.new(File.join(@dir, "cache")).read_project_snapshot
      refute_nil(loaded)
      loaded = loaded #: as !nil

      record = loaded[path]
      refute_nil(record)
      assert_equal([123.0, 45], record[:fingerprint])
      assert_equal(entries.map(&:name), record[:entries].map(&:name))
    end

    def test_project_snapshot_schema_mismatch_is_a_miss
      @cache.write_project_snapshot({ "x.rb" => { fingerprint: [1.0, 2], entries: [] } })

      path = File.join(@dir, "cache", "__project__.dump")
      payload = Marshal.load(File.binread(path)) #: as Hash[Symbol, untyped]
      payload[:schema_version] = IndexCache::SCHEMA_VERSION + 1
      File.binwrite(path, Marshal.dump(payload))

      assert_nil(@cache.read_project_snapshot)
    end

    def test_prune_preserves_the_project_snapshot
      @cache.write("foo-1.0.0", index_entries("class Bar; end"))
      @cache.write_project_snapshot({ "x.rb" => { fingerprint: [1.0, 2], entries: [] } })

      # Prune with no valid gem keys: the gem cache goes away, but the project snapshot is left untouched
      @cache.prune!([])

      cache_dir = File.join(@dir, "cache")
      refute_path_exists(File.join(cache_dir, "foo-1.0.0.dump"))
      assert_path_exists(File.join(cache_dir, "__project__.dump"))
    end

    private

    #: (String source) -> Array[Entry]
    def index_entries(source)
      index = Index.new
      index.index_single(@uri, source)
      index.instance_variable_get(:@uris_to_entries)[@uri.to_s] || []
    end
  end
end
