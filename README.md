# QOSI_TP3

Project: QOSI Course TP3 Experimental Code Collection

Brief Description:  
This repository contains implementation code for the third practical assignment (TP3) of the QOSI course, primarily concerning Virtual Network Functions (VNFs), host and server simulation, access control, traffic monitoring, and rate limiting/policy modules. The repository is organised into multiple subdirectories by functional module for ease of development and testing.

---

## Directory Structure (Overview)
- Host/  
  Host-related code (potentially used to simulate client or terminal host behaviour, initiate requests, or receive data).  
- Server/  
  Server-related code (potentially used to simulate backend services, process requests, or host VNFs).  
- VNF_Class/  
  Classes/implementations related to VNF (Virtual Network Function). Contains class definitions implementing VNF behaviour and common base classes.  
- VNF_Monitor/  
  Monitoring classes/scripts for collecting/reporting VNF or network traffic statistics, status probes, etc.  
- VNF_Police/  
  Traffic policing (rate limiting/discard) implementations for VNFs enforcing bandwidth/packet rate restriction policies.  
- Vnf_Access/  
  Access control implementations for rule-based access control or authorisation checks.  
- python ssh_eve.py  
  Script located in the root directory. script for interacting with/issuing commands to a specific host ("Eve") via SSH,  used for automated testing.
