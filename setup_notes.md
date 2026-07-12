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

