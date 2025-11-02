# LikeC4 Architecture Diagrams

This folder contains architecture diagrams as code using [LikeC4](https://likec4.dev/), a tool for creating architecture visualizations based on the C4 model.

## Files

- **mysaas.c4** - Architecture model for a sample SaaS platform
  - Defines actors, systems, services, and components
  - Includes landscape, container, and component views
  - Shows a multi-tier architecture with React frontend, backend services (Auth, Billing, Data Processing), PostgreSQL database, and Kafka message bus

- **specs.c4** - Style specifications and element type definitions
  - Defines visual styling for actors, systems, services, components, databases, and message buses
  - Configures relationship styles (e.g., async connections)

- **runLocal.sh** - Script to run the LikeC4 viewer locally using Docker

## Usage

### View Diagrams Locally

Run the local viewer:

```bash
./runLocal.sh
```

This starts the LikeC4 server on:
- **Port 5173** - Main web interface
- **Port 24678** - Development server

Open your browser to `http://localhost:5173` to view and interact with the architecture diagrams.

### Edit Diagrams

Simply edit the `.c4` files. If the local server is running, changes will be automatically reloaded.

## Prerequisites

- Docker installed and running

## Learn More

- [LikeC4 Documentation](https://likec4.dev/)
- [C4 Model](https://c4model.com/)