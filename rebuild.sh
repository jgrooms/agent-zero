#!/bin/bash
cd ~/agent-zero-fork
docker compose down
docker compose up --build -d
