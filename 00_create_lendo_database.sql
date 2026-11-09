-- LENDO — създаване на базата данни
-- Изпълни този файл само ако базата `lendo` все още НЕ съществува.
-- В pgAdmin се свържи към съществуващата база `postgres` и изпълни:

CREATE DATABASE lendo
    WITH OWNER = postgres
         ENCODING = 'UTF8'
         TEMPLATE = template0;
