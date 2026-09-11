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
static const uint8_t ORVTF_WAIT = 1 << 3;       ///< Keep waiting at this station until road vehicles have been loaded.

/**
 * Selection criteria of a carrier's "load road vehicles" order: the loader only takes road vehicles
 * which satisfy every criterion which is in use ("no match, skip this vehicle"), in the same spirit
 * as the coupling parameters of the px-patch train coupling feature.
 */
enum RVTransportLoadState : uint8_t {
	RVTLS_ANY   = 0, ///< Any road vehicle.
	RVTLS_EMPTY = 1, ///< Only an empty road vehicle.
	RVTLS_FULL  = 2, ///< Only a fully loaded road vehicle.
};

/** Cargo criterion of a carrier's "load road vehicles" order. */
enum RVTransportCargoMode : uint8_t {
	RVTC_ANY        = 0, ///< Any cargo.
	RVTC_CAN_CARRY  = 1, ///< The road vehicle must be able to carry the given cargo.
	RVTC_IS_CARRYING = 2, ///< The road vehicle must currently carry the given cargo.
};

/** Does this station order select road vehicles by any criterion? */
bool RVTransportOrderHasCriteria(const class Order &order);

/**
 * Would this station order take the given road vehicle as a candidate? Applies the destination
 * match, the load state, the cargo and the minimum waiting time criteria of the order.
 */
bool RVTransportOrderAllowsCandidate(const Vehicle *carrier, const Vehicle *rv);

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

/**
 * Set/clear the "waiting to be transported" state of a road vehicle.
 * @param waiting Whether the vehicle waits for a carrier.
 */
void RVTransportSetWaiting(Vehicle *rv, bool waiting);

/**
 * Called for every ticked road vehicle: ends the "waiting to be transported" state when the vehicle
 * was told to do something else in the meantime (the player skipped the order, sent it to a depot,
 * ...). Without this the vehicle would keep sitting at the station with the waiting flag set, and a
 * "go to depot" order would never be carried out because the vehicle stays stopped.
 */
void RVTransportTickWaiting(Vehicle *rv);

/**
 * Toggle one road vehicle transport flag of a station order, keeping the combination meaningful:
 * the destination match and waiting only make sense while road vehicles are loaded, and a road
 * vehicle's own order never uses the destination match.
 * @param flags Current order flags (ORVTF_* bits).
 * @param bit The single flag to toggle.
 * @param is_road_vehicle Whether the order belongs to a road vehicle (rather than to a carrier).
 * @return The new flags.
 */
uint8_t RVTransportToggleOrderFlag(uint8_t flags, uint8_t bit, bool is_road_vehicle);

/** Try to load one road vehicle onto a carrier part. Returns true when carried. */
bool RVTransportAttach(Vehicle *carrier, Vehicle *part, Vehicle *rv, bool force = false);

/** Try to attach a road vehicle to any suitable part of the carrier. */
bool RVTransportAttachAuto(Vehicle *carrier, Vehicle *rv, bool force = false);

/**
 * Unload road vehicles carried by this carrier at the given station. Returns true if anything was unloaded.
 * @param force unload every carried road vehicle, even the ones which want to get off somewhere else
 *        (debug only).
 */
bool RVTransportDetachAtStation(Vehicle *carrier, Station *st, bool force = false);

/**
 * How many road vehicles this carrier still carries which want to be dropped at this station (their
 * own "be unloaded here" order, or no declared destination at all). Used to keep a carrier which was
 * told to wait for road vehicles waiting until the station has room for them.
 */
uint32_t RVTransportCountWantingUnloadHere(const Vehicle *carrier, const Station *st);

/**
 * Find the first road vehicle waiting to be transported at this station which satisfies the
 * selection criteria of the carrier's current order (see RVTransportOrderAllowsCandidate()).
 * @param st Station to look at.
 * @param carrier Carrier which wants to load; when given, its order criteria are applied.
 */
Vehicle *RVTransportFindWaitingAtStation(const Station *st, const Vehicle *carrier = nullptr);

/** Number of road vehicles currently carried by this carrier (front vehicle). */
uint32_t RVTransportCountOnCarrier(const Vehicle *carrier);

/** First road vehicle currently carried by this carrier (front vehicle), or nullptr. */
Vehicle *RVTransportFindFirstOnCarrier(const Vehicle *carrier);

/**
 * Vehicle whose position represents this vehicle on the map: a carried road vehicle is where its
 * carrier is. Used by the camera/viewport follow ("centre on vehicle") and other actions which
 * need the position of a vehicle.
 */
const Vehicle *RVTransportGetFollowVehicle(const Vehicle *v);

/**
 * Destroy the road vehicles carried by this carrier: they are lost together with it (as when a
 * train crashes), instead of being left behind on the map.
 */
void RVTransportDestroyCarriedVehicles(Vehicle *carrier);

/**
 * Fix up the carried state of all road vehicles after a savegame was loaded (a road vehicle whose
 * carrier does not exist any more is put back on the road).
 */
void RVTransportValidateAfterLoad();

/**
 * Emergency release of a carried road vehicle, used when its carrier is destroyed: the road
 * vehicle is put back on the road network at its remembered tile and continues on its own.
 */
void RVTransportForceRelease(Vehicle *rv);

#endif /* ROADVEH_TRANSPORT_H */
