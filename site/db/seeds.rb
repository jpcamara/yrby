# db:prepare loads schema.rb instead of replaying migrations on a fresh
# database. Provision the one public example there too; repeated seeds are safe.
ExampleDocument.find_or_create_by!(id: 1)
