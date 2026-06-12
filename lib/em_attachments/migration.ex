defmodule EmAttachments.Migration do
  @moduledoc """
  Ecto migration helpers for em_attachments.

  Import this module inside an `Ecto.Migration` to get the
  `create_uploads_table/1` macro.

      defmodule MyApp.Repo.Migrations.CreateEmAttachmentsUploads do
        use Ecto.Migration
        import EmAttachments.Migration

        def change do
          create_uploads_table()
        end
      end

  ## Options

    * `:schema` — database schema name (string or atom). When given, the macro
      emits `CREATE SCHEMA IF NOT EXISTS` and creates the table with a prefix.
      Defaults to `"em_attachments"` on PostgreSQL when auto-detected by
      `mix em_attachments.gen.migration`.

    * `:table` — table name atom. Defaults to `:uploads` when `:schema` is set,
      `:em_attachments_uploads` otherwise.

  ## Examples

      # Auto-detects adapter: uses em_attachments.uploads on Postgres,
      # em_attachments_uploads flat table on other adapters.
      create_uploads_table()

      # Explicit schema (overrides auto-detection)
      create_uploads_table(schema: "em_attachments")

      # Opt out of schema even on Postgres
      create_uploads_table(schema: nil)

      # Custom table and schema
      create_uploads_table(schema: "myapp", table: :file_uploads)

  """

  defmacro create_uploads_table(opts \\ []) do
    schema_stmts =
      quote do
        schema_name =
          case Keyword.fetch(unquote(opts), :schema) do
            {:ok, val} ->
              val

            :error ->
              if repo().__adapter__() == Ecto.Adapters.Postgres, do: "em_attachments", else: nil
          end

        schema_str = if schema_name, do: to_string(schema_name), else: nil
        table_atom = Keyword.get(unquote(opts), :table, if(schema_str, do: :uploads, else: :em_attachments_uploads))

        if schema_str do
          execute("CREATE SCHEMA IF NOT EXISTS \"#{schema_str}\"")
        end

        create table(table_atom, prefix: schema_str) do
          add(:asset_id, :string, null: false)
          add(:uploader, :string, null: false)
          add(:serialized, :text, null: false)
          add(:status, :string, null: false, default: "pending")
          add(:expires_at, :utc_datetime_usec, null: false)
          timestamps(updated_at: false)
        end

        create(index(table_atom, [:status, :expires_at], prefix: schema_str))
        create(unique_index(table_atom, [:asset_id], prefix: schema_str))

        notify = Keyword.get(unquote(opts), :notify, true)

        if notify and repo().__adapter__() == Ecto.Adapters.Postgres do
          qualified_table =
            if schema_str,
              do: "\"#{schema_str}\".\"#{table_atom}\"",
              else: "\"#{table_atom}\""

          fn_schema = if schema_str, do: "\"#{schema_str}\".", else: ""
          fn_name = "#{fn_schema}em_attachments_notify"

          execute(
            """
            CREATE OR REPLACE FUNCTION #{fn_name}()
            RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE payload text;
            BEGIN
              IF TG_OP = 'DELETE' THEN
                payload := '{"op":"DELETE"}';
              ELSE
                payload := '{"op":"' || TG_OP || '","status":"' || NEW.status || '"}';
              END IF;
              PERFORM pg_notify('em_attachments_uploads', payload);
              RETURN NULL;
            END;
            $$;
            """,
            "DROP FUNCTION IF EXISTS #{fn_name}();"
          )

          execute(
            """
            CREATE TRIGGER em_attachments_notify_trigger
            AFTER INSERT OR UPDATE OR DELETE ON #{qualified_table}
            FOR EACH ROW EXECUTE FUNCTION #{fn_name}();
            """,
            "DROP TRIGGER IF EXISTS em_attachments_notify_trigger ON #{qualified_table};"
          )
        end
      end

    schema_stmts
  end
end
