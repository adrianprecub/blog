# JobRunr Demo

A simple demonstration of [JobRunr](https://www.jobrunr.io/) - a distributed background job processing framework for Java.

## Features

- In-memory storage provider for job persistence
- Built-in web dashboard for job monitoring
- Background job server for processing jobs
- Examples of enqueueing and scheduling jobs

## Prerequisites

- Java 21 or higher
- Maven (included via Maven Wrapper)

## Running the Project

### Build the project

```bash
./mvnw clean compile
```

### Run the application

```bash
./mvnw exec:java -Dexec.mainClass="com.jobrunr.Main"
```

Alternatively, compile and run directly:

```bash
./mvnw clean package
java -jar target/jobrunr-1.0.0-SNAPSHOT.jar
```

## Accessing the Dashboard

Once the application is running, access the JobRunr dashboard at:

```
http://localhost:8000
```

The dashboard allows you to monitor:
- Enqueued jobs
- Scheduled jobs
- Processing jobs
- Succeeded/failed jobs
- Recurring jobs

## What This Demo Does

The application demonstrates:

1. **Immediate Job Execution**: Enqueues a background job that prints "This is a background job!"
2. **Scheduled Job**: Schedules a job to run 5 minutes from now that prints "This is a scheduled job!"

Both jobs can be monitored through the web dashboard.

## Dependencies

- **JobRunr** (8.1.0): Background job processing framework
- **Jackson Databind** (2.17.0): JSON serialization/deserialization

## Project Structure

```
jobrunr/
├── src/main/java/com/jobrunr/
│   └── Main.java          # Main application entry point
├── pom.xml                # Maven configuration
└── README.md             # This file
```