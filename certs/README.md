rds-global-bundle.pem: Amazon RDS root and intermediate CAs for all regions.

Source: https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
Used by the ingest Lambda (sslmode=verify-full) and the Grafana data source
(tlsCACert) to verify the RDS server certificate. Public certificates, safe
to commit. Refresh when AWS publishes a new CA generation.
