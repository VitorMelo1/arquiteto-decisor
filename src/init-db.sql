-- Schemas isolados por microsserviço (Database per Service pattern)
-- Cada serviço acessa apenas o seu próprio schema

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS content;
CREATE SCHEMA IF NOT EXISTS learning;
CREATE SCHEMA IF NOT EXISTS analytics;
