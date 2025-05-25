# bebop-vapor

💧 A project built with the Vapor web framework.

## Getting Started

To build the project using the Swift Package Manager, run the following command in the terminal from the root of the project:
```bash
swift build
```

To run the project and start the server, use the following command:
```bash
swift run
```

To execute tests, use the following command:
```bash
swift test
```

## Deployment

The project ships with a `Dockerfile` and a `docker-compose.yml` for running
the application inside a container. Build the Docker image and start the app
service with the following commands:

```bash
docker compose build
docker compose up app
```

The application will be available on port `8080` by default.

### See more

- [Vapor Website](https://vapor.codes)
- [Vapor Documentation](https://docs.vapor.codes)
- [Vapor GitHub](https://github.com/vapor)
- [Vapor Community](https://github.com/vapor-community)

