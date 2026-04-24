package postgreslistener

import (
	"fmt"

	"github.com/project-flogo/core/data/coerce"
)

// Settings structure for the PostgreSQL Listener Trigger
type Settings struct {
	// Connection settings
	Host         string `md:"host,required"`         // PostgreSQL server host
	Port         int    `md:"port,required"`         // PostgreSQL server port
	User         string `md:"user,required"`         // Database user
	Password     string `md:"password,required"`     // Database password
	DatabaseName string `md:"databaseName,required"` // Database name

	// SSL/TLS settings
	SSLMode    string `md:"sslMode"`    // SSL mode (disable, require, verify-ca, verify-full)
	TLSConfig  bool   `md:"tlsConfig"`  // Enable TLS configuration
	TLSMode    string `md:"tlsMode"`    // TLS mode (VerifyCA, VerifyFull)
	Cacert     string `md:"cacert"`     // CA certificate (base64 encoded)
	Clientcert string `md:"clientcert"` // Client certificate (base64 encoded)
	Clientkey  string `md:"clientkey"`  // Client key (base64 encoded)

	// Connection management
	ConnectionTimeout    int `md:"connectionTimeout"`    // Connection timeout in seconds
	MaxConnRetryAttempts int `md:"maxConnRetryAttempts"` // Maximum connection retry attempts
	ConnectionRetryDelay int `md:"connectionRetryDelay"` // Delay between connection retries in seconds
}

// GetConnectionDetails returns connection details from the settings
func (s *Settings) GetConnectionDetails() (*ConnectionDetails, error) {
	if s.Host == "" || s.Port == 0 || s.User == "" || s.DatabaseName == "" {
		return nil, fmt.Errorf("host, port, user, and databaseName are required")
	}

	return &ConnectionDetails{
		Host:         s.Host,
		Port:         s.Port,
		User:         s.User,
		Password:     s.Password,
		DatabaseName: s.DatabaseName,
		SSLMode:      s.SSLMode,
	}, nil
}

// ConnectionDetails represents database connection information
type ConnectionDetails struct {
	Host         string
	Port         int
	User         string
	Password     string
	DatabaseName string
	SSLMode      string
}

// HandlerSettings structure for individual channels to listen on
type HandlerSettings struct {
	Channel string `md:"channel,required"` // The PostgreSQL channel to listen on
}

// Output structure for the data received from PostgreSQL NOTIFY
type Output struct {
	Payload string `md:"payload"` // The payload string from the NOTIFY message
}

// ToMap method for Output (required by Flogo)
func (o *Output) ToMap() map[string]interface{} {
	return map[string]interface{}{
		"payload": o.Payload,
	}
}

// FromMap method for Output (required by Flogo)
func (o *Output) FromMap(values map[string]interface{}) error {
	var err error
	o.Payload, err = coerce.ToString(values["payload"])
	if err != nil {
		return err
	}
	return nil
}
