# S3 Testbed Setup Notes

## SeaweedFS
- Ports: 9333 (master), 8080 (volume), 8888 (S3 gateway)
- Command: docker run -d --name seaweedfs -p 9333:9333 -p 8080:8080 -p 8888:8888 chrislusf/seaweedfs server -s3
- Dashboard: http://localhost:9333

## RustFS
- Ports: 9000 (S3 API), 9001 (dashboard)
- Command: docker run -d --name rustfs -p 9000:9000 -p 9001:9001 -e RUSTFS_ROOT_USER=minioadmin -e RUSTFS_ROOT_PASSWORD=minioadmin rustfs/rustfs server /data
- Dashboard: http://localhost:9001
- Login: minioadmin / minioadmin


## Garage
- Ports: 3900 (S3 API), 3901 (RPC), 3902 (admin)
- Requires config file at ~/garage.toml and data dirs at ~/garage-data
- RPC secret must be exactly 64 hex characters generated via: openssl rand -hex 32
- Command: docker run -d --name garage -p 3900:3900 -p 3901:3901 -p 3902:3902 -v ~/garage-data:/var/lib/garage -v ~/garage.toml:/etc/garage.toml dxflrs/garage:v1.0.0
- Dashboard: No web UI — managed via CLI or admin API at http://localhost:3902
