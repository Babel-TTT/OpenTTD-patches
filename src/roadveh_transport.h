/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <http://www.gnu.org/licenses/>.
 */

/** @file roadveh_transport.h Road vehicles carried by other vehicles (RoRo). */

#ifndef ROADVEH_TRANSPORT_H
#define ROADVEH_TRANSPORT_H

#include "core/enum_type.hpp"
#include "station_type.h"
#include "vehicle_type.h"

class Vehicle;
struct Station;

/** Bits stored in Vehicle::rv_transport_flags. */
static const uint8_t RVTF_WAITING     = 1 << 0; ///< Road vehicle waits at a station to be loaded onto a carrier.
static const uint8_t RVTF_TRANSPORTED = 1 << 1; ///< Road vehicle is currently carried by another vehicle (off the road network).

/** Bits stored in OrderExtraInfo::rv_transport_flags. */
static const uint8_t ORVTF_LOAD   = 1 << 0; ///< This station order loads road vehicles onto the carrier.
static const uint8_t ORVTF_UNLOAD = 1 << 1; ///< This station order unloads road vehicles from the carrier.
static const uint8_t ORVTF_MATCH_DEST = 1 << 2; ///< Only load road vehicles whose declared unload station equals the carrier's next stop.

/** Station a road vehicle wants to be unloaded at (from its own "unload road vehicles" order), or invalid. */
StationID RVTransportGetDeclaredDestination(const Vehicle *rv);

/** Next station the carrier stops at after its current order, or invalid. */
StationID RVTransportGetNextCarrierStop(const Vehicle *carrier);

/** Weight in tonnes a road vehicle occupies on a carrier (rounded up). */
uint32_t RVTransportGetVehicleWeightTonnes(const Vehicle *rv);

/** Transport capacity in tonnes of a carrier part (based on its current cargo and capacity). */
uint32_t RVTransportGetPartCapacityTonnes(const Vehicle *part);

/** Tonnes already used on this carrier part by carried road vehicles. */
uint32_t RVTransportGetPartUsedTonnes(const Vehicle *part);

/** Can this carrier part carry road vehicles at all (cargo class oversized)? */
bool RVTransportPartCanCarry(const Vehicle *part);

/** Set/clear the "waiting to be transported" state of a road vehicle. */
void RVTransportSetWaiting(Vehicle *rv, bool waiting);

/** Try to load one road vehicle onto a carrier part. Returns true when carried. */
bool RVTransportAttach(Vehicle *carrier, Vehicle *part, Vehicle *rv, bool force = false);

/** Try to attach a road vehicle to any suitable part of the carrier. */
bool RVTransportAttachAuto(Vehicle *carrier, Vehicle *rv, bool force = false);

/** Unload all road vehicles carried by this carrier at the given station. Returns true if anything was unloaded. */
bool RVTransportDetachAtStation(Vehicle *carrier, Station *st);

/**
 * Find the first road vehicle waiting to be transported at this station.
 * @param st Station to look at.
 * @param carrier Carrier which wants to load; used for the destination match.
 * @param match_destination When true, only vehicles whose declared unload station equals the carrier's next stop are considered.
 */
Vehicle *RVTransportFindWaitingAtStation(const Station *st, const Vehicle *carrier = nullptr, bool match_destination = false);

/** Number of road vehicles currently carried by this carrier (front vehicle). */
uint32_t RVTransportCountOnCarrier(const Vehicle *carrier);

/** First road vehicle currently carried by this carrier (front vehicle), or nullptr. */
Vehicle *RVTransportFindFirstOnCarrier(const Vehicle *carrier);

#endif /* ROADVEH_TRANSPORT_H */
