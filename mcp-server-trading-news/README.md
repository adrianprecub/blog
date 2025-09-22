# Trading News MCP Server

A Model Context Protocol (MCP) server built with Quarkus that provides trading news functionality by integrating with Alpha Vantage's News & Sentiment API.

## Overview

This MCP server exposes trading news data as tools that can be used by MCP clients like Claude Desktop or other AI assistants. It provides both general trading news and ticker-specific news with sentiment analysis.

## Features

- **General Trading News**: Retrieve general trading and financial news
- **Ticker-Specific News**: Get news articles filtered by specific stock tickers
- **Sentiment Analysis**: News articles include sentiment scores and labels
- **RESTful API**: Traditional REST endpoints for direct HTTP access
- **MCP Tools**: Exposed as MCP tools for AI assistant integration

## Architecture

The server is built using:
- **Quarkus**: Cloud-native Java framework for fast startup and low memory footprint
- **MCP Server SSE**: Quarkus extension for MCP protocol support
- **JAX-RS**: RESTful web services
- **REST Client**: For Alpha Vantage API integration
- **Jackson**: JSON processing

## Prerequisites

- Java 21 or higher
- Maven 3.8.1 or higher
- Alpha Vantage API key

## Configuration

### Environment Variables

Set the following environment variable:
```bash
export ALPHAVANTAGE_API_KEY=your_api_key_here
```

### Application Configuration

The server runs on port 8082 by default. Configuration is managed in `src/main/resources/application.properties`:

```properties
# Server port
quarkus.http.port=8082

# MCP server configuration
quarkus.mcp.server.server-info.name=Trading News Service
quarkus.mcp.server.traffic-logging.enabled=true

# Alpha Vantage API configuration
quarkus.rest-client."alphavantagenews".uri=https://www.alphavantage.co/
alphaVantage.api.key=${ALPHAVANTAGE_API_KEY:demo}
```

## Installation & Running

### Development Mode

Start the server in development mode with hot reloading:

```bash
./mvnw quarkus:dev
```

### Production Build

Build and run the application:

```bash
# Build
./mvnw clean package

# Run the uber-jar
java -jar target/mcp-server-trading-news-1.0.0-SNAPSHOT-runner.jar
```

### Native Build

For faster startup and lower memory usage:

```bash
./mvnw package -Pnative
./target/mcp-server-trading-news-1.0.0-SNAPSHOT-runner
```

## API Endpoints

### REST API

- **GET** `/trading/news/general` - Get general trading news
- **GET** `/trading/news/tickers?tickers=AAPL,GOOGL` - Get news for specific tickers

### MCP Tools

When connected as an MCP server, the following tools are available:

1. **get_trading_news** - Retrieve general trading news
2. **get_trading_news_by_tickers** - Get news filtered by comma-separated tickers

## Usage Examples

### REST API

```bash
# Get general trading news
curl http://localhost:8082/trading/news/general

# Get news for specific tickers
curl "http://localhost:8082/trading/news/tickers?tickers=AAPL,TSLA,GOOGL"
```

### MCP Client Integration

Connect to the MCP server using the Server-Sent Events (SSE) protocol on `http://localhost:8082/mcp/sse`.

Example tools usage:
- `get_trading_news()` - Returns general trading news with sentiment analysis
- `get_trading_news_by_tickers("AAPL,TSLA")` - Returns news specific to Apple and Tesla stocks

## Data Model

### NewsResponse
- `items`: Number of news items returned
- `sentimentScoreDefinition`: Definition of sentiment scoring
- `relevanceScoreDefinition`: Definition of relevance scoring
- `feed`: Array of news articles

### NewsArticle
- `title`: Article headline
- `url`: Link to full article
- `timePublished`: Publication timestamp
- `authors`: List of article authors
- `summary`: Article summary
- `source`: News source
- `overallSentimentScore`: Numerical sentiment score
- `overallSentimentLabel`: Sentiment label (Positive, Negative, Neutral)
- `topics`: Array of relevant topics with relevance scores

## Development

### Project Structure

```
src/main/java/com/trading/news/
├── AlphaVantageTools.java          # MCP tools definitions
├── TradingNewsService.java         # REST endpoint controller
├── AlphaVantageNewsClient.java     # REST client interface
└── model/
    ├── NewsResponse.java           # Response wrapper model
    └── NewsArticle.java           # News article model
```

### Adding New Features

1. Extend `AlphaVantageTools.java` for new MCP tools
2. Add endpoints to `TradingNewsService.java` for REST API
3. Update `AlphaVantageNewsClient.java` for new API calls
4. Create model classes in the `model` package as needed

## Testing

Run the test suite:

```bash
./mvnw test
```

## Monitoring & Logging

- MCP traffic logging is enabled for debugging
- REST client request/response logging is configured
- Logs are available in the console output

## Troubleshooting

### Common Issues

1. **API Key Issues**: Ensure `ALPHAVANTAGE_API_KEY` environment variable is set
2. **Port Conflicts**: Change port in `application.properties` if 8082 is in use
3. **Network Issues**: Verify connectivity to `https://www.alphavantage.co/`

### Rate Limiting

Alpha Vantage has API rate limits. The free tier allows:
- 5 API requests per minute
- 500 API requests per day

## License

This project is licensed under the Apache License 2.0.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## Support

For issues and questions:
- Check the Alpha Vantage API documentation
- Review Quarkus MCP extension documentation
- Open an issue in the project repository