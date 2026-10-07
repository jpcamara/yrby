# On a fresh database, db:prepare loads schema.rb and skips the migrations, so
# the seeds create the public example too. Running them again is safe.
ExampleDocument.find_or_create_by!(id: 1)
