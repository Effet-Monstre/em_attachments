Drop cache store
create a task that will generate a table we will use to store info about cached assets
Insert infos about assets in this table when creating "cache" assets during cast_attachments
Mark these assets "permanent" in prepare_changes (Will rollback if db failure) don't do uploads/updates anymore during prepare_changes
Have a GenServer that delete assets that are still in this table after they have been created for longer than the expiry date
Have the GenServer take permanent asset and run an optional update call (new callback on the backend implementation) (ex change permissions) with props provided by the config. Then delete asset row from table.
Make sure Assets that were removed manually outside app controlled are understood to be deleted so that we don,t run delete tasks forever on these assets, piling up in the db table.
change way we do config so that it better reflect the new way of doing things.
Update pipeline / plugin and backends to better fit this new way of doing things.
Fix tests (remove add if needed)
