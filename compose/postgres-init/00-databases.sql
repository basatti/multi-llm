-- Create the three databases the local harness needs.
-- POSTGRES_DB (litellm) is created automatically by the postgres image;
-- these are the additional ones.
CREATE DATABASE langfuse;
CREATE DATABASE orchestration;
