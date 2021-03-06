# Sensu plugin for running InfluxDB queries

A sensu plugin that extends Sensu with the ability to run queries against InfluxDB.

This is generally useful when you have to evaluate an issue using some analytics functions (e.g. moving average, derivative etc.).

The plugin generates multiple OK/WARN/CRIT/UNKNOWN events via the sensu client socket (https://sensuapp.org/docs/latest/clients#client-socket-input),
making sure to override the client source (in the check result) so that the check shows up as if it was triggered by the original sensu client. The client
source is overriden ONLY if the host field (--host-field) is present in the results returned by the InfluxDB query.

The plugin is inspired by https://github.com/sensu-plugins/sensu-plugins-influxdb.

## Usage

The plugin accepts the following command line options:

```
Usage: check-influxdb-q.rb (options)
        --check-name <CHECK_NAME>    Check name (default: %{name}-%{tags.instance}-%{tags.type})
    -c, --crit <EXPR>                Critical expression (e.g. value >= 10)
        --database <DATABASE>        InfluxDB database (default: collectd)
        --dryrun                     Do not send events to sensu client socket
        --handlers <HANDLER>         Comma separated list of handlers
        --host <HOST>                InfluxDB host (default: localhost)
        --host-field <FIELD>         InfluxDB measurement host field (default: host)
    -j, --json-path <PATH>           JSON path for value matching (docs at http://goessner.net/articles/JsonPath)
    -m, --msg <MESSAGE>              Message to use for OK/WARNING/CRITICAL, supports variable interpolation (e.g. %{tags.instance}) (required)
        --port <PORT>                InfluxDB port (default: 8086)
    -q, --query <QUERY>              Query to execute [e.g. SELECT DERIVATIVE(LAST(value), 1m) AS value FROM interface_rx WHERE type = 'if_errors' AND time > now() - 5m group by time(1m), host, instance, type fill(none)] (required)
        --timeout <SECONDS>          InfluxDB query timeout (default: 3)
        --use-ssl                    InfluxDB SSL (default: false)
    -w, --warn <EXPR>                Warning expression (e.g. value >= 5)
```

Use the --handlers command line option to specify which handlers you want to use for the generated events.

## Example

A typical example could be the monitoring of interface errors when using the 'interface' collectd plugin.


```
check-influxdb-q.rb -q "SELECT DERIVATIVE(LAST(value), 1m) AS value FROM interface_rx WHERE type = 'if_errors' AND time > now() - 5m group by time(1m), host, instance, type fill(none)" -j '$.values[-1].value' -w 'value > 0' --msg "Number of RX errors on interface %{tags.instance}"
```

An handy feature is the ability to interpolate the query result hash attributes into the --check-name and --msg command line flags.

So, for query above the result might look like the following (run without --json-path to inspect the result):

```
{"name"=>"interface_rx", "tags"=>{"instance"=>"ens255f0", "type"=>"if_errors"}, "values"=>[{"time"=>"2016-01-07T21:43:00Z", "value"=>0}, {"time"=>"2016-01-07T21:44:00Z", "value"=>0}, {"time"=>"2016-01-07T21:45:00Z", "value"=>0}, {"time"=>"2016-01-07T21:46:00Z", "value"=>0}, {"time"=>"2016-01-07T21:47:00Z", "value"=>0}]}
```

In this case, you can interpolate the following variables: %{name}, %{tags.instance}, %{tags.type}, %{values.0.value} ..

## Author
Matteo Cerutti - <matteo.cerutti@hotmail.co.uk>
