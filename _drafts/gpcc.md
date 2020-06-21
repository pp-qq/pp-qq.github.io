

gpccws

gpperfmon db

the query metrics collection extension

The gpperfmon agents forward collected data to an agent on the Greenplum Database master. 

The real-time query metrics agents submit collected data directly to the Command Center rpc port(gpcc backend ccagent). real-time

Greenplum Database calls the query metrics extension when a query is first submitted, when a query’s status changes, and when a node in the query execution plan initializes, starts, or finishes. The query metrics extension sends metrics to the metrics collection agent running on each segment host.


Greenplum Database sends UDP packets at various points during query execution. The gpsmon process on each segment host collects the data. Periodically, every 15 seconds by default, a gpmmon agent on the master host signals the gpsmon process to forward the collected data. The agent on the master host receives the data and adds it to the gpperfmon database. (过时了吧... 现在架构)

The metrics_collection extension is included with Pivotal Greenplum Database. The extension is enabled by setting the gp_enable_query_metrics server configuration parameter to on and restarting the Greenplum Database cluster. The metrics collection agent is installed on each host when you install Greenplum Command Center. The Command Center application monitors the agent and restarts it if needed.



Greenplum Command Center uses gpperfmon for historical data only; it uses the real-time query metrics to monitor active and queued queries. 

The now and tail data are stored as text files on the master host file system, and the Command Center database accesses them via external tables. The history tables are regular database tables stored within the gpperfmon database.

The Command Center metrics collection agent, ccagent, runs on segment hosts and receives real-time metrics emitted by the metrics collection database extension. Each segment host has one ccagent process. The metrics collection extension connects to ccagent using Unix Domain Sockets (UDS) to transfer metrics from Greenplum Database. 

The Greenplum Database gpperfmon_install utility enables the gpmmon and gpsmon data collection agents. Greenplum Command Center no longer requires the history data these agents collect. You can run the gpperfmon data collection agents and the Command Center metrics collection agents in parallel, but unless you need the data the gpperfmon agents collect for some other purpose, you can improve the Greenplum Database system performance by disabling the gpperfmon agents.

The metrics collection agent ccagent runs queries on Greenplum Database on behalf of Command Center to perform activities such as retrieving information to display in the Command Center UI, saving state in the gpperfmon and postgres databases, inserting alert event records, and harvesting query history for the gpmetrics history tables. The agent runs these queries using the gpmon database role.