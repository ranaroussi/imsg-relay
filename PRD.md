# imsg-relay

## Product requirements document

### Version

1.0

### Status

Draft

### Working name

imsg-relay

---

# Executive summary

imsg-relay is a macOS menu bar application that turns a Mac into an iMessage gateway.

The application uses the open-source imsg project to communicate with Apple's Messages ecosystem and exposes iMessage functionality to remote systems through:

- Event relays
- HTTP APIs
- MCP tools
- Cloudflare Tunnel connectivity

The Mac acts as a lightweight edge node while all business logic, AI workflows, CRM integration, automation, storage, and orchestration remain on a remote server.

The goal is to provide a reliable, production-ready bridge between iMessage and external systems without requiring direct access to Apple's infrastructure.

---

# Problem statement

Organizations and developers want to integrate iMessage into:

- AI agents
- Customer support systems
- CRM platforms
- Sales workflows
- Automation platforms
- Internal tools

Apple does not provide a practical server-side iMessage API.

imsg-relay solves this by transforming a Mac into a secure iMessage gateway that can be controlled remotely.

---

# Product goals

## Primary goals

- Turn any Mac into an iMessage gateway
- Relay inbound messages to a remote server
- Allow remote systems to send outbound messages
- Support attachments
- Support message lifecycle events
- Expose MCP tools
- Require minimal user configuration
- Operate reliably with automatic recovery

## Non-goals

- CRM functionality
- Conversation management
- AI assistants
- Analytics
- Workflow builders
- Customer databases
- Multi-tenant SaaS management

These responsibilities belong to the remote server.

---

# Architecture

text Messages.app        │        ▼      imsg        │        ▼   imsg-relay        │        ├── Event relay        ├── Local HTTP API        ├── MCP server        ├── Attachment handling        ├── Retry queue        └── Cloudflare Tunnel                  │                  ▼           Remote server 

---

# Core principles

## Dumb edge node

The Mac should perform only:

- Message access
- Message delivery
- Event forwarding
- Local API hosting
- Tunnel management

All decision-making occurs remotely.

## Event-driven

All communication should be event-based.

## Reliable delivery

Messages must not be lost during:

- Internet outages
- Server outages
- Application restarts
- Tunnel reconnects

---

# Configuration

## Required settings

### Server endpoint

text https://server.example.com/imessage 

Destination for outbound events.

### Server identifier

User-defined identifier.

Examples:

text sales support personal marketing 

---

# Event envelope

All events sent to the remote server use the following structure.

json {   "server": {     "identifier": "sales",     "endpoint": "https://server.example.com/imessage",     "callback_url": "https://relay.example.trycloudflare.com"   },   "event": {     "type": "message.received",     "timestamp": "2026-06-08T12:34:56Z"   },   "data": {} } 

---

# Event types

## Message events

### message.received

Triggered when a new message arrives.

### message.sent

Triggered when a message is sent.

### message.delivered

Triggered when a message is delivered.

### message.read

Triggered when a message is marked as read.

### message.reaction

Triggered when a tapback or reaction occurs.

### message.edited

Triggered when a message is edited.

### message.unsent

Triggered when a message is recalled.

---

## Chat events

### chat.created

Triggered when a new chat appears.

### chat.updated

Triggered when a chat changes.

---

## Attachment events

### attachment.received

Triggered when an attachment arrives.

### attachment.sent

Triggered when an attachment is sent.

---

## System events

### relay.started

### relay.stopped

### relay.error

### tunnel.connected

### tunnel.disconnected

### tunnel.changed

---

# Attachment support

## Requirements

Support:

- Images
- Videos
- Audio
- PDFs
- Documents
- Multiple attachments per message

Example:

json {   "attachments": [     {       "filename": "photo.jpg",       "mime_type": "image/jpeg",       "size": 145628     }   ] } 

## Attachment retrieval

Attachments should be retrievable through:

- API
- MCP
- Event callbacks

---

# Local HTTP API

## Status

http GET /health GET /status GET /stats 

## Chats

http GET /chats GET /chats/{id} 

## History

http GET /history 

Parameters:

text chat_id limit before after 

## Search

http GET /search/messages GET /search/chats 

## Messaging

http POST /send POST /send/attachment 

---

# MCP interface

The MCP server should expose all major capabilities.

## Tools

text imsg_list_chats imsg_get_chat imsg_get_history imsg_search_messages imsg_search_chats imsg_send_message imsg_send_attachment imsg_get_attachment imsg_get_status 

The MCP layer should map directly to internal service methods.

---

# Cloudflare Tunnel

## Responsibilities

- Create tunnel
- Maintain tunnel
- Detect failures
- Reconnect automatically
- Update callback URL

## Callback URL

The current callback URL is included in every event.

Example:

json {   "server": {     "callback_url": "https://relay.example.trycloudflare.com"   } } 

---

# Reliability

## Retry queue

Outbound events must be stored locally before transmission.

If delivery fails:

text Store event Retry Confirm delivery Remove from queue 

## Local persistence

Store:

- Pending events
- Retry attempts
- Tunnel state
- Cursor positions

Suggested implementation:

text SQLite 

---

# Contact resolution

Where available, return:

json {   "phone": "+447700900123",   "display_name": "John Smith" } 

This is a convenience feature and should not require full contact synchronization.

---

# Menu bar application

## Status display

Show:

- Relay status
- Tunnel status
- Server status
- Queue size

## Actions

- Open settings
- View logs
- Restart relay
- Restart tunnel
- Quit

---

# Dependencies

## Required

### imsg

Used for:

- Monitoring messages
- Sending messages
- Chat access
- Message history

### cloudflared

Used for:

- Secure remote connectivity
- Callback URL exposure

---

# Multi-account support

A single Mac may host multiple Apple IDs through separate macOS user sessions.

Each session runs:

- One imsg instance
- One relay instance
- One API instance
- One MCP instance
- One tunnel

The remote server identifies each relay through:

json {   "server": {     "identifier": "sales"   } } 

No machine identifier is required.

---

# Success criteria

## Functional

- Receive inbound messages
- Send outbound messages
- Send and receive attachments
- Search messages
- Search chats
- Expose MCP tools
- Maintain Cloudflare Tunnel
- Recover from failures

## Reliability

- No message loss during temporary outages
- Automatic reconnection
- Persistent retry queue
- Resume processing after restart

---

# Future roadmap

## Version 1.1

- Named tunnel support
- Remote diagnostics
- Automatic updates
- Better contact resolution

## Version 1.2

- Fleet monitoring
- Centralized relay management
- Relay health dashboards

## Version 2.0

- Hosted relay management service
- Multi-machine orchestration
- Enterprise deployment tooling
