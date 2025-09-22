# Trading News MCP Server - Architecture Diagram

```mermaid
graph TB
    subgraph "Client Layer"
        A[Claude Desktop]
        B[MCP Client]
        C[HTTP Client]
    end

    subgraph "MCP Server (Quarkus)"
        D[MCP SSE Endpoint<br>/mcp/sse]
        E[REST API<br>/trading/news]
        F[AlphaVantageTools<br>@Tool Methods]
        G[TradingNewsService<br>@Path Controller]
        H[AlphaVantageNewsClient<br>@RestClient]

        subgraph "Models"
            I[NewsResponse]
            J[NewsArticle]
            K[Topic]
        end

        L[Configuration<br>application.properties]
    end

    subgraph "External API"
        M[Alpha Vantage<br>News & Sentiment API<br>www.alphavantage.co]
    end

    subgraph "Environment"
        N[ALPHAVANTAGE_API_KEY<br>Environment Variable]
    end

    %% Client connections
    A -->|MCP Protocol<br>SSE| D
    B -->|MCP Protocol<br>SSE| D
    C -->|HTTP REST| E

    %% Internal flow
    D --> F
    E --> G
    F --> H
    G --> H

    %% External API calls
    H -->|HTTPS GET<br>?function=NEWS_SENTIMENT<br>&topics=general<br>&apikey=xxx| M
    H -->|HTTPS GET<br>?function=NEWS_SENTIMENT<br>&tickers=AAPL,TSLA<br>&apikey=xxx| M

    %% Models
    H --> I
    I --> J
    J --> K

    %% Configuration
    L --> H
    L --> F
    L --> G
    N --> L

    %% Response flow
    M -->|JSON Response| H
    H --> I
    I --> F
    I --> G
    F --> D
    G --> E
    D -->|MCP Response| A
    D -->|MCP Response| B
    E -->|JSON Response| C

    %% Styling
    classDef clientClass fill:#e1f5fe
    classDef serverClass fill:#f3e5f5
    classDef externalClass fill:#fff3e0
    classDef modelClass fill:#e8f5e8
    classDef configClass fill:#fce4ec

    class A,B,C clientClass
    class D,E,F,G,H serverClass
    class M externalClass
    class I,J,K modelClass
    class L,N configClass
```

## Architecture Overview

### Components

#### Client Layer
- **Claude Desktop**: AI assistant that connects via MCP protocol
- **MCP Client**: Any client implementing MCP protocol
- **HTTP Client**: Direct REST API consumers (curl, browser, etc.)

#### MCP Server (Quarkus Application)
- **MCP SSE Endpoint**: Server-Sent Events endpoint for MCP protocol communication
- **REST API**: Traditional HTTP REST endpoints for direct access
- **AlphaVantageTools**: MCP tool definitions using `@Tool` annotations
- **TradingNewsService**: JAX-RS controller with `@Path` mappings
- **AlphaVantageNewsClient**: REST client interface for external API calls
- **Models**: Data transfer objects for JSON serialization/deserialization
- **Configuration**: Application properties and environment variable handling

#### External Services
- **Alpha Vantage API**: Third-party financial news and sentiment data provider

### Data Flow

1. **MCP Client Request**: Claude Desktop sends MCP tool request via SSE
2. **Tool Execution**: AlphaVantageTools methods are invoked
3. **External API Call**: REST client makes HTTP request to Alpha Vantage
4. **Data Processing**: JSON response is mapped to model objects
5. **Response Return**: Structured data returned via MCP protocol

### Alternative REST Flow

1. **HTTP Request**: Direct REST client makes HTTP call
2. **Controller Processing**: TradingNewsService handles the request
3. **External API Call**: Same REST client integration
4. **JSON Response**: Direct JSON response to HTTP client

### Configuration Management

- **Environment Variables**: API keys stored securely
- **Application Properties**: Server configuration and REST client settings
- **Quarkus Configuration**: Framework-level settings for MCP and REST

### Key Design Patterns

- **Dependency Injection**: Quarkus CDI for component wiring
- **REST Client Pattern**: Declarative HTTP client interface
- **MCP Tool Pattern**: Annotation-based tool exposure
- **Model Mapping**: Jackson annotations for JSON processing
- **Configuration Injection**: MicroProfile Config for settings

### Security Considerations

- **API Key Management**: Environment variable injection
- **HTTPS**: Secure communication with external APIs
- **Input Validation**: Query parameter validation
- **Rate Limiting**: Handled by Alpha Vantage API

### Scalability Features

- **Cloud-Native**: Quarkus optimized for containers
- **Fast Startup**: Sub-second startup times
- **Low Memory**: Minimal memory footprint
- **Native Compilation**: GraalVM native image support