#!/bin/bash

NOBULLSEYE=1 NOBUSTER=1 make configure PLATFORM=vpp
NOBULLSEYE=1 NOBUSTER=1 make target/sonic-vpp.img.gz