/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <http://www.gnu.org/licenses/>.
 */

/** @file roadveh_transport.cpp Road vehicles carried by other vehicles (RoRo): core transactions. */

#include "stdafx.h"

#include "roadveh_transport.h"

#include "cargotype.h"
#include "date_func.h"
#include "direction_func.h"
#include "direction_type.h"
#include "map_func.h"
#include "order_base.h"
#include "road_map.h"
#include "roadveh.h"
#include "settings_type.h"
#include "station_base.h"
#include "station_map.h"
#include "tilearea_type.h"
#include "vehicle_base.h"

#include "safeguards.h"

/** Weight of a road vehicle in tonnes (including its current cargo), from the consist weight cache. */
uint32_t RVTransportGetVehicleWeightTonnes(const Vehicle *rv)
{
	if (rv == nullptr || rv->type != VehicleType::Road) return 0;
	if (!rv->IsFrontEngine()) return 0;
	return RoadVehicle::From(rv)->gcache.cached_weight;
}

/** Is this carrier part able to carry road vehicles? */
bool RVTransportPartCanCarry(const Vehicle *part)
{
	if (part == nullptr) return false;
	if (part->cargo_cap == 0) return false;
	if (!IsValidCargoType(part->cargo_type)) return false;
	if (!_settings_game.vehicle.rv_transport_require_oversized) return true; // default: any part with cargo capacity
	return IsCargoInClass(part->cargo_type, CargoClass::Oversized);
}

/** Transport capacity of a carrier part in tonnes, derived from its cargo capacity. */
uint32_t RVTransportGetPartCapacityTonnes(const Vehicle *part)
{
	if (!RVTransportPartCanCarry(part)) return 0;
	const CargoSpec *cs = CargoSpec::Get(part->cargo_type);
	/* CargoSpec::weight is in 1/16 tonne units per cargo unit. */
	return static_cast<uint32_t>(part->cargo_cap) * cs->weight / 16;
}

/** Tonnes already used on this carrier part by carried road vehicles. */
uint32_t RVTransportGetPartUsedTonnes(const Vehicle *part)
{
	if (part == nullptr) return 0;
	uint32_t used = 0;
	for (const Vehicle *v : Vehicle::Iterate()) {
		if ((v->rv_transport_flags & RVTF_TRANSPORTED) == 0) continue;
		if (v->transported_host_part != part->index) continue;
		used += v->transported_weight;
	}
	return used;
}

/** Number of road vehicles currently carried by this carrier. */
uint32_t RVTransportCountOnCarrier(const Vehicle *carrier)
{
	if (carrier == nullptr) return 0;
	uint32_t count = 0;
	for (const Vehicle *v : Vehicle::Iterate()) {
		if ((v->rv_transport_flags & RVTF_TRANSPORTED) == 0) continue;
		if (v->transported_by != carrier->index) continue;
		count++;
	}
	return count;
}

/** First carried road vehicle of this carrier, or nullptr. */
Vehicle *RVTransportFindFirstOnCarrier(const Vehicle *carrier)
{
	if (carrier == nullptr) return nullptr;
	for (Vehicle *v : Vehicle::Iterate()) {
		if ((v->rv_transport_flags & RVTF_TRANSPORTED) == 0) continue;
		if (v->transported_by != carrier->index) continue;
		return v;
	}
	return nullptr;
}

/** Set or clear the "waiting to be transported" state; a waiting vehicle is stopped. */
void RVTransportSetWaiting(Vehicle *rv, bool waiting)
{
	if (rv == nullptr || rv->type != VehicleType::Road) return;
	if ((rv->rv_transport_flags & RVTF_TRANSPORTED) != 0) return; // carried vehicles are not waiting

	if (waiting) {
		rv->rv_transport_flags |= RVTF_WAITING;
		rv->transport_wait_tick = static_cast<uint32_t>(_tick_counter);
		rv->vehstatus.Set(VehState::Stopped);
		rv->cur_speed = 0;
	} else {
		rv->rv_transport_flags &= ~RVTF_WAITING;
		rv->transport_wait_tick = 0;
		rv->vehstatus.Reset(VehState::Stopped);
	}
	SetWindowDirty(WindowClass::VehicleView, rv->index);
	SetWindowDirty(WindowClass::VehicleDetails, rv->index);
}

/**
 * Toggle one road vehicle transport flag of a station order, keeping the combination meaningful:
 * the destination match and waiting only make sense while road vehicles are loaded, and a road
 * vehicle's own order never uses the destination match.
 */
uint8_t RVTransportToggleOrderFlag(uint8_t flags, uint8_t bit, bool is_road_vehicle)
{
	const bool enabling = (flags & bit) == 0;

	switch (bit) {
		case ORVTF_LOAD:
			if (enabling) {
				flags |= ORVTF_LOAD;
				/* Default to taking only road vehicles heading for the carrier's next stop; the player
				 * can switch that off again with the entry of its own. */
				if (is_road_vehicle) {
					flags &= ~(ORVTF_MATCH_DEST | ORVTF_WAIT);
				} else {
					flags |= ORVTF_MATCH_DEST;
				}
			} else {
				flags &= ~(ORVTF_LOAD | ORVTF_MATCH_DEST | ORVTF_WAIT);
			}
			break;

		case ORVTF_MATCH_DEST:
		case ORVTF_WAIT:
			/* Both are only meaningful while road vehicles are loaded here. */
			flags = enabling ? (flags | bit | ORVTF_LOAD) : (flags & ~bit);
			break;

		case ORVTF_UNLOAD:
			flags = enabling ? (flags | ORVTF_UNLOAD) : (flags & ~ORVTF_UNLOAD);
			break;

		default:
			NOT_REACHED();
	}

	return flags;
}

/**
 * Load one road vehicle onto a carrier part: the road vehicle leaves the road network
 * and is remembered by the carrier (single tick commit, no intermediate state).
 * @param force skip the cargo class / capacity checks (used by the debug self test).
 */
bool RVTransportAttach(Vehicle *carrier, Vehicle *part, Vehicle *rv, bool force)
{
	extern void UpdateVehicleTileHash(Vehicle *v, bool remove);

	if (carrier == nullptr || part == nullptr || rv == nullptr) return false;
	if (carrier->type == VehicleType::Road) return false; // carriers are trains/ships/aircraft, not road vehicles
	if (rv->type != VehicleType::Road) return false;
	if (!rv->IsFrontEngine()) return false;              // articulated road vehicles: later stage
	if (rv->Next() != nullptr) return false;             // do not carry multi-part road vehicles (yet)
	if ((rv->rv_transport_flags & RVTF_TRANSPORTED) != 0) return false;
	if (part->First() != carrier) return false;          // part must belong to this carrier
	if (!force && !RVTransportPartCanCarry(part)) return false;

	uint32_t weight = RVTransportGetVehicleWeightTonnes(rv);
	if (weight == 0) weight = 1;
	if (!force) {
		const uint32_t capacity = RVTransportGetPartCapacityTonnes(part);
		const uint32_t used = RVTransportGetPartUsedTonnes(part);
		if (used + weight > capacity) return false;      // refused: no room on this part
	}

	/* commit */
	rv->rv_transport_flags &= ~RVTF_WAITING;
	rv->rv_transport_flags |= RVTF_TRANSPORTED;
	rv->transported_by = carrier->index;
	rv->transported_host_part = part->index;
	rv->transported_weight = static_cast<uint16_t>(std::min<uint32_t>(weight, UINT16_MAX));

	rv->vehstatus.Set(VehState::Stopped);
	rv->vehstatus.Set(VehState::Hidden);
	rv->cur_speed = 0;
	UpdateVehicleTileHash(rv, true);   // off the road network (like virtual vehicles)
	rv->UpdateIsDrawn();

	carrier->MarkDirty();              // refresh carrier weight; must be the front (CargoChanged asserts this->First() == this)
	return true;
}

/** Try to load a road vehicle onto any suitable part of the carrier. */
bool RVTransportAttachAuto(Vehicle *carrier, Vehicle *rv, bool force)
{
	if (carrier == nullptr) return false;
	for (Vehicle *part = carrier; part != nullptr; part = part->Next()) {
		if (RVTransportAttach(carrier, part, rv, force)) return true;
	}
	return false;
}

/** Find a free road stop tile in this station plus an exit direction with road. */
static bool FindFreeRoadStopTile(const Station *st, TileIndex &out_tile, DiagDirection &out_dd)
{
	for (int pass = 0; pass < 2; pass++) {
		const TileArea &area = (pass == 0) ? st->bus_station : st->truck_station;
		for (TileIndex t : area) {
			if (!IsAnyRoadStopTile(t)) continue;
			if (GetFirstVehicleOnTile(t, VehicleType::Road) != nullptr) continue;
			for (DiagDirection dd = DiagDirection::Begin; dd < DiagDirection::End; dd++) {
				TileIndex next = TileAddByDiagDir(t, dd);
				if (!IsValidTile(next)) continue;
				if (IsNormalRoadTile(next) || IsAnyRoadStopTile(next)) {
					out_tile = t;
					out_dd = dd;
					return true;
				}
			}
		}
	}
	return false;
}

/**
 * Unload road vehicles carried by this carrier at the given station.
 * @return true if at least one road vehicle reached the road network.
 */
bool RVTransportDetachAtStation(Vehicle *carrier, Station *st)
{
	extern void UpdateVehicleTileHash(Vehicle *v, bool remove);

	if (carrier == nullptr || st == nullptr) return false;

	bool any = false;
	for (Vehicle *v : Vehicle::Iterate()) {
		if ((v->rv_transport_flags & RVTF_TRANSPORTED) == 0) continue;
		if (v->transported_by != carrier->index) continue;
		if (!v->IsFrontEngine()) continue;
		if (v->Next() != nullptr) continue;

		TileIndex tile = INVALID_TILE;
		DiagDirection dd = DiagDirection::NE;
		if (!FindFreeRoadStopTile(st, tile, dd)) continue; // no room: stay on the carrier, retry later

		/* commit */
		v->rv_transport_flags &= ~RVTF_TRANSPORTED;
		v->transported_by = VehicleID::Invalid();
		v->transported_host_part = VehicleID::Invalid();
		v->transported_weight = 0;
		v->transport_wait_tick = 0;

		RoadVehicle *rv = RoadVehicle::From(v);
		v->tile = tile;
		v->x_pos = TileX(tile) * TILE_SIZE + TILE_SIZE / 2;
		v->y_pos = TileY(tile) * TILE_SIZE + TILE_SIZE / 2;
		v->z_pos = GetSlopePixelZ(v->x_pos, v->y_pos);
		v->direction = DiagDirToDir(dd);
		rv->state = DiagDirToDiagTrackdir(dd);
		rv->frame = 0;
		v->progress = 0;
		v->cur_speed = 0;
		v->vehstatus.Reset(VehState::Hidden);
		v->vehstatus.Reset(VehState::Stopped);
		UpdateVehicleTileHash(v, false);   // back on the road network
		v->UpdateIsDrawn();

		carrier->MarkDirty();
		any = true;
	}
	return any;
}

/**
 * Station at which a road vehicle wants to be unloaded, taken from the first of its own
 * station orders which asks for unloading road vehicles ("declared destination").
 * @return The station id, or an invalid id when the vehicle declares no destination.
 */
StationID RVTransportGetDeclaredDestination(const Vehicle *rv)
{
	if (rv == nullptr) return StationID::Invalid();
	for (const Order *o : rv->Orders()) {
		if (!o->IsType(OT_GOTO_STATION)) continue;
		if ((o->GetRVTransportFlags() & ORVTF_UNLOAD) != 0) return o->GetDestination().ToStationID();
	}
	return StationID::Invalid();
}

/**
 * Next station the carrier stops at after its current order.
 * @return The station id, or an invalid id when there is none.
 */
StationID RVTransportGetNextCarrierStop(const Vehicle *carrier)
{
	if (carrier == nullptr || carrier->orders == nullptr) return StationID::Invalid();
	const OrderList *ol = carrier->orders;
	const VehicleOrderID num = ol->GetNumOrders();
	for (VehicleOrderID i = static_cast<VehicleOrderID>(carrier->cur_real_order_index + 1); i < num; i++) {
		const Order *o = ol->GetOrderAt(i);
		if (o != nullptr && o->IsType(OT_GOTO_STATION)) return o->GetDestination().ToStationID();
	}
	return StationID::Invalid();
}

/**
 * First road vehicle waiting to be transported at this station.
 * @param st Station to look at.
 * @param carrier Carrier which wants to load; used for the destination match.
 * @param match_destination When true only road vehicles whose declared unload station equals
 *        the carrier's next stop are considered; other waiting vehicles are skipped.
 */
Vehicle *RVTransportFindWaitingAtStation(const Station *st, const Vehicle *carrier, bool match_destination)
{
	if (st == nullptr) return nullptr;
	const StationID next_stop = match_destination ? RVTransportGetNextCarrierStop(carrier) : StationID::Invalid();
	for (Vehicle *v : Vehicle::Iterate()) {
		if ((v->rv_transport_flags & RVTF_WAITING) == 0) continue;
		if (v->type != VehicleType::Road) continue;
		if (!v->IsFrontEngine()) continue;
		if (v->last_station_visited != st->index) continue;
		if (match_destination) {
			const StationID dest = RVTransportGetDeclaredDestination(v);
			if (dest != next_stop) continue; // not for this carrier's next stop: skip it
		}
		return v;
	}
	return nullptr;
}

/**
 * Emergency release: put a carried road vehicle back on the road network at its remembered
 * tile. Used when its carrier is destroyed, so that the vehicle does not keep pointing at a
 * deleted carrier. The vehicle keeps its own orders and simply continues on its way.
 */
void RVTransportForceRelease(Vehicle *rv)
{
	extern void UpdateVehicleTileHash(Vehicle *v, bool remove);

	if (rv == nullptr) return;
	if ((rv->rv_transport_flags & Vehicle::RV_TRANSPORT_CARRIED) == 0) return;

	rv->rv_transport_flags &= ~Vehicle::RV_TRANSPORT_CARRIED;
	rv->transported_by = VehicleID::Invalid();
	rv->transported_host_part = VehicleID::Invalid();
	rv->transported_weight = 0;
	rv->vehstatus.Reset(VehState::Hidden);
	rv->vehstatus.Reset(VehState::Stopped);
	rv->cur_speed = 0;

	if (rv->type == VehicleType::Road && IsValidTile(rv->tile)) {
		RoadVehicle *rvv = RoadVehicle::From(rv);
		rv->x_pos = TileX(rv->tile) * TILE_SIZE + TILE_SIZE / 2;
		rv->y_pos = TileY(rv->tile) * TILE_SIZE + TILE_SIZE / 2;
		rv->z_pos = GetSlopePixelZ(rv->x_pos, rv->y_pos);
		rv->direction = DiagDirToDir(DiagDirection::NE);
		rvv->state = DiagDirToDiagTrackdir(DiagDirection::NE);
		rvv->frame = 0;
		UpdateVehicleTileHash(rv, false);   // back on the road network
	}
	rv->UpdateIsDrawn();
}
