# make a space delimited list of firewalls

The default allows all IPs to connect to the database.
DDOS attack will cost money database is accepting connection.
`DB_FIREWALL="0.0.0.0/0"`

# note all of the sleep uses prime numbers make it easier to cancel with pgrep and pkill

- cancel automatic stop of objects
```
pkill -f "sleep 113m"
```
- cancel automatic delete of the database
```
pkill -f "sleep 127m"
```

- to stop the automatic delete of the pipelines
```
pkill -f "sleep 131m"
```

# Using random for for security 

- hostname (database name)
- catalog name
- user name