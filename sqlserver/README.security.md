The database host firewall are open to public connection.
This allows easier demo where egress IP of the gateway is not known.
To protect the database, the following are reset each new demo start.

export DB_BASENAME=${DB_HOST:-$(pwgen -1AB 8)}
export DB_CATALOG=${DB_CATALOG:-$(pwgen -1AB 8)}

export DBA_USERNAME=${DBA_USERNAME:-$(pwgen -1AB 8)}
export USER_USERNAME=${USER_USERNAME:-$(pwgen -1AB 8)}

export DBA_PASSWORD="${DBA_PASSWORD:-$(pwgen -1y -r \.\@\\\>\`\"\'\| 16 )}"
export USER_PASSWORD=${USER_PASSWORD:-$(pwgen -1y -r \.\@\\\>\`\"\'\| 16 )}

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