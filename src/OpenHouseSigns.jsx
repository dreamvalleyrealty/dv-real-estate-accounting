import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { supabase } from "./lib/supabase";
import {
  AlertTriangle, CalendarDays, Camera, CheckCircle2, Clock3, ExternalLink,
  History, LoaderCircle, MapPin, MapPinned, Navigation, Plus, RefreshCw,
  Route, Search, Signpost, Trash2, X
} from "lucide-react";
import "./OpenHouseSigns.css";

const PHOTO_BUCKET = "dv-open-house-sign-photos";
const MAPS_KEY = import.meta.env.VITE_GOOGLE_MAPS_API_KEY || "";

function loadGoogleMaps() {
  if (window.google?.maps?.places) return Promise.resolve(window.google);
  if (window.__dvMapsPromise) return window.__dvMapsPromise;
  window.__dvMapsPromise = new Promise((resolve, reject) => {
    window.__dvGoogleMapsInit = () => resolve(window.google);
    const existing = document.getElementById("dv-google-maps");
    if (existing) {
      existing.addEventListener("error", () => reject(new Error("Google Maps could not load.")), { once: true });
      return;
    }
    const script = document.createElement("script");
    script.id = "dv-google-maps";
    script.async = true;
    script.defer = true;
    script.src = "https://maps.googleapis.com/maps/api/js?key=" + encodeURIComponent(MAPS_KEY) + "&libraries=places&v=weekly&callback=__dvGoogleMapsInit";
    script.onerror = () => reject(new Error("Google Maps could not load. Check the API key and enabled Google Maps APIs."));
    document.head.appendChild(script);
  });
  return window.__dvMapsPromise;
}

const distanceKm = (a, b) => {
  if (!a || !b) return Infinity;
  const rad = n => n * Math.PI / 180;
  const dLat = rad(b.lat - a.lat), dLng = rad(b.lng - a.lng);
  const x = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
};
const prettyDate = value => value ? new Date(value + "T12:00:00").toLocaleDateString("en-CA", { year: "numeric", month: "short", day: "numeric" }) : "Date not set";
const errorText = error => error?.message || String(error || "Something went wrong.");

export default function OpenHouseSigns({ user, agentId, role = "AGENT", adminMode = false }) {
  const mapElement = useRef(null);
  const mapRef = useRef(null);
  const markersRef = useRef([]);
  const geocoderRef = useRef(null);
    const routePolylinesRef = useRef([]);
  const mapClickRef = useRef(null);
  const [companyId, setCompanyId] = useState("");
  const [agentName, setAgentName] = useState("");
  const [agents, setAgents] = useState([]);
  const [selectedAgentId, setSelectedAgentId] = useState(agentId || "");
  const [events, setEvents] = useState([]);
  const [locations, setLocations] = useState([]);
  const [eventSigns, setEventSigns] = useState([]);
  const [activeEventId, setActiveEventId] = useState("");
  const [mapReady, setMapReady] = useState(false);
  const [mapError, setMapError] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [showNewEvent, setShowNewEvent] = useState(false);
  const [eventForm, setEventForm] = useState({ property_address: "", start_time: "13:00", end_time: "16:00", notes: "" });
  const [dateRows, setDateRows] = useState([{ event_date: "", start_time: "13:00", end_time: "16:00" }]);
  const [templateEventId, setTemplateEventId] = useState("");
  const [pendingPoint, setPendingPoint] = useState(null);
  const [pointForm, setPointForm] = useState({ label: "Directional sign", direction: "", notes: "" });
  const [suggestions, setSuggestions] = useState([]);
  const [suggesting, setSuggesting] = useState(false);
  const [query, setQuery] = useState("");
  const [showHistory, setShowHistory] = useState(false);
  const [photoBusyId, setPhotoBusyId] = useState("");
  const [routeBusy, setRouteBusy] = useState(false);
  const [selectedTab, setSelectedTab] = useState("plan");

  const activeEvent = useMemo(() => events.find(event => event.id === activeEventId) || null, [events, activeEventId]);
  const propertyPoint = useMemo(() => activeEvent?.property_lat != null && activeEvent?.property_lng != null
    ? { lat: Number(activeEvent.property_lat), lng: Number(activeEvent.property_lng) } : null, [activeEvent]);
  const nearbyLocations = useMemo(() => {
    if (!propertyPoint) return [];
    return locations.filter(location => location.active && distanceKm(propertyPoint, { lat: Number(location.latitude), lng: Number(location.longitude) }) <= 5)
      .sort((a, b) => distanceKm(propertyPoint, { lat: Number(a.latitude), lng: Number(a.longitude) }) - distanceKm(propertyPoint, { lat: Number(b.latitude), lng: Number(b.longitude) }));
  }, [locations, propertyPoint]);
  const filteredEvents = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return events.filter(event => !needle || String(event.property_address || "").toLowerCase().includes(needle) || String(event.agent_name || "").toLowerCase().includes(needle));
  }, [events, query]);

  const loadDirectories = useCallback(async (cid) => {
    if (!supabase || !cid) return;
    const [eventResult, locationResult, agentResult] = await Promise.all([
      supabase.from("dv_open_house_events").select("*").eq("company_id", cid).order("event_date", { ascending: false }).order("created_at", { ascending: false }),
      supabase.from("dv_open_house_sign_locations").select("*").eq("company_id", cid).eq("active", true).order("last_used_at", { ascending: false, nullsFirst: false }).order("created_at", { ascending: false }),
      supabase.from("dv_accounting_agents").select("id,name,first_name,last_name,email").eq("company_id", cid)
    ]);
    if (eventResult.error) throw eventResult.error;
    if (locationResult.error) throw locationResult.error;
    if (agentResult.error) throw agentResult.error;
    const agentRows = agentResult.data || [];
    setAgents(agentRows);
    const agentMap = new Map(agentRows.map(agent => [agent.id, agent.name || [agent.first_name, agent.last_name].filter(Boolean).join(" ") || agent.email || "Agent"]));
    const rows = (eventResult.data || []).map(event => ({ ...event, agent_name: agentMap.get(event.agent_id) || (event.created_by === user?.id ? agentName || "You" : "Agent") }));
    setEvents(rows);
    setLocations(locationResult.data || []);
    if (!activeEventId && rows.length) setActiveEventId(rows[0].id);
  }, [activeEventId, agentName, user?.id]);

  useEffect(() => {
    let cancelled = false;
    async function init() {
      if (!supabase || !user?.id) { setLoading(false); setError("Please sign in to use Open House Signs."); return; }
      try {
        const { data: profile, error: profileError } = await supabase.from("dv_accounting_user_profiles").select("company_id,display_name,role,active").eq("user_id", user.id).maybeSingle();
        if (profileError) throw profileError;
        if (profile?.active === false) throw new Error("Your Back Office account is inactive.");
        let cid = profile?.company_id || "";
        let agent = null;
        if (agentId) {
          const { data, error: agentError } = await supabase.from("dv_accounting_agents").select("id,company_id,name,first_name,last_name").eq("id", agentId).maybeSingle();
          if (agentError) throw agentError;
          agent = data;
          cid = cid || data?.company_id || "";
        }
        if (!cid && ["SUPERADMIN","ADMIN","MANAGER","BROKER","BROKER_OF_RECORD","BROKER OF RECORD","OWNER"].includes(String(role || profile?.role || "").toUpperCase())) {
          const { data: company, error: companyError } = await supabase.from("dv_accounting_companies").select("id").limit(1).maybeSingle();
          if (companyError) throw companyError;
          cid = company?.id || "";
        }
        if (!cid) throw new Error("Your account is not linked to a brokerage company. Ask an administrator to check your agent profile.");
        if (cancelled) return;
        setCompanyId(cid);
        setAgentName(agent?.name || [agent?.first_name, agent?.last_name].filter(Boolean).join(" ") || profile?.display_name || user.email || "Agent");
        await loadDirectories(cid);
      } catch (e) {
        if (!cancelled) setError(errorText(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    init();
    return () => { cancelled = true; };
  }, [agentId, user?.id, role, loadDirectories]);

  useEffect(() => {
    if (!activeEventId || !supabase) { setEventSigns([]); return; }
    let cancelled = false;
    supabase.from("dv_open_house_event_signs")
      .select("*,location:dv_open_house_sign_locations(*)")
      .eq("event_id", activeEventId).order("sequence", { ascending: true })
      .then(({ data, error: fetchError }) => {
        if (cancelled) return;
        if (fetchError) setError(errorText(fetchError));
        else setEventSigns((data || []).filter(row => row.location));
      });
    return () => { cancelled = true; };
  }, [activeEventId]);

  // Load the Google Maps API and Geocoder independently of the visible map.
  // The first open house cannot exist yet, so the map canvas is not rendered
  // until after creation. Requiring the canvas here creates a circular dependency.
  useEffect(() => {
    if (!MAPS_KEY) {
      setMapError("Google Maps is not configured yet. Add VITE_GOOGLE_MAPS_API_KEY to the Back Office hosting environment.");
      return;
    }
    let cancelled = false;
    loadGoogleMaps().then(google => {
      if (cancelled) return;
      geocoderRef.current = new google.maps.Geocoder();
      setMapError("");
      setMapReady(true);
    }).catch(e => {
      if (!cancelled) setMapError(errorText(e));
    });
    return () => { cancelled = true; };
  }, []);

  // Create the visible map only after an open house exists and its map canvas
  // has been rendered. The Geocoder is already available for the first save.
  useEffect(() => {
    if (!mapReady || !mapElement.current || mapRef.current) return;
    const google = window.google;
    if (!google?.maps || !geocoderRef.current) return;
    const center = propertyPoint || { lat: 43.6532, lng: -79.3832 };
    const map = new google.maps.Map(mapElement.current, {
      center, zoom: propertyPoint ? 14 : 11, mapTypeControl: false,
      streetViewControl: false, fullscreenControl: true, clickableIcons: false,
      gestureHandling: "greedy", mapId: undefined
    });
    mapRef.current = map;
    mapClickRef.current = map.addListener("click", async event => {
      if (!event.latLng) return;
      const point = { lat: event.latLng.lat(), lng: event.latLng.lng() };
      let address = "Pinned map location";
      try {
        const result = await geocoderRef.current.geocode({ location: point });
        address = result.results?.[0]?.formatted_address || address;
      } catch {}
      setPendingPoint({ ...point, address });
      setPointForm({ label: "Directional sign", direction: "", notes: "" });
    });
  }, [mapReady, activeEventId, propertyPoint]);

  useEffect(() => {
    if (!mapReady || !mapRef.current) return;
    const google = window.google;
    markersRef.current.forEach(marker => marker.setMap(null));
    markersRef.current = [];
    routePolylinesRef.current.forEach(polyline => polyline.setMap(null));
    routePolylinesRef.current = [];
    if (propertyPoint) {
      const marker = new google.maps.Marker({ map: mapRef.current, position: propertyPoint, title: activeEvent?.property_address || "Open house property", label: { text: "P", color: "#fff", fontWeight: "700" }, icon: { path: google.maps.SymbolPath.CIRCLE, scale: 12, fillColor: "#0f2141", fillOpacity: 1, strokeColor: "#fff", strokeWeight: 2 } });
      markersRef.current.push(marker);
      mapRef.current.panTo(propertyPoint);
      mapRef.current.setZoom(14);
    }
    eventSigns.forEach((item, index) => {
      const location = item.location;
      const installed = item.status === "INSTALLED";
      const marker = new google.maps.Marker({
        map: mapRef.current, position: { lat: Number(location.latitude), lng: Number(location.longitude) },
        title: location.label + " · " + location.address,
        label: { text: String(index + 1), color: "#fff", fontWeight: "700" },
        icon: { path: google.maps.SymbolPath.CIRCLE, scale: 11, fillColor: installed ? "#3f765d" : "#9e8556", fillOpacity: 1, strokeColor: "#fff", strokeWeight: 2 }
      });
      markersRef.current.push(marker);
    });
    if (!propertyPoint && eventSigns.length) {
      const bounds = new google.maps.LatLngBounds();
      eventSigns.forEach(item => bounds.extend({ lat: Number(item.location.latitude), lng: Number(item.location.longitude) }));
      mapRef.current.fitBounds(bounds);
    }
  }, [mapReady, propertyPoint, eventSigns, activeEvent?.property_address]);

  const geocodeAddress = useCallback(async address => {
    if (!geocoderRef.current) throw new Error("Google Maps is still loading.");
    const result = await geocoderRef.current.geocode({ address });
    const hit = result.results?.[0];
    if (!hit) throw new Error("Google Maps could not find that address. Check the spelling and postal code.");
    return { lat: hit.geometry.location.lat(), lng: hit.geometry.location.lng(), formatted: hit.formatted_address };
  }, []);

  async function createEvent(event) {
    event.preventDefault();
    setError(""); setMessage("");
    if (!companyId || !supabase) return;
    if (adminMode && !selectedAgentId) { setError("Select the agent this open house is being created for."); return; }
    if (!MAPS_KEY || !geocoderRef.current) { setError("Google Maps must be configured before creating an open house."); return; }
    setSaving(true);
    try {
      const point = await geocodeAddress(eventForm.property_address);
      const dates = dateRows.filter(row => row.event_date);
      if (!dates.length) throw new Error("Add at least one open house date.");
      if (new Set(dates.map(row => row.event_date)).size !== dates.length) throw new Error("Each open house date must be unique.");
      const assignedAgentId = adminMode ? selectedAgentId : (agentId || activeEvent?.agent_id || null);
      const assignedAgent = agents.find(agent => agent.id === assignedAgentId);
      const assignedName = assignedAgent?.name || [assignedAgent?.first_name, assignedAgent?.last_name].filter(Boolean).join(" ") || agentName;
      const createdEvents = [];
      for (const row of dates) {
        const { data, error: insertError } = await supabase.from("dv_open_house_events").insert({
          company_id: companyId, agent_id: assignedAgentId, created_by: user.id,
          property_address: eventForm.property_address.trim(), property_lat: point.lat, property_lng: point.lng,
          event_date: row.event_date, start_time: row.start_time || null,
          end_time: row.end_time || null, notes: eventForm.notes.trim() || null
        }).select("*").single();
        if (insertError) throw insertError;
        createdEvents.push({ ...data, agent_name: assignedName || "Agent" });
        if (templateEventId && eventSigns.length) {
          const copies = eventSigns.map((sign,index) => ({ company_id: companyId, event_id: data.id, sign_location_id: sign.sign_location_id, sequence: index + 1, status: "PLANNED" }));
          const { error: copyError } = await supabase.from("dv_open_house_event_signs").insert(copies);
          if (copyError) throw copyError;
        }
      }
      setEvents(prev => [...createdEvents, ...prev]);
      if (createdEvents.length) setActiveEventId(createdEvents[0].id);
      setEventForm({ property_address: "", start_time: "13:00", end_time: "16:00", notes: "" });
      setDateRows([{ event_date: "", start_time: "13:00", end_time: "16:00" }]);
      setTemplateEventId("");
      setShowNewEvent(false);
      setMessage(createdEvents.length + " open house date(s) saved. Each date has its own sign checklist.");
    } catch (e) { setError(errorText(e)); }
    finally { setSaving(false); }
  }

  async function attachLocation(location) {
    if (!activeEvent || !supabase) return;
    if (eventSigns.some(item => item.sign_location_id === location.id)) { setMessage("That location is already on this open house plan."); return; }
    setSaving(true); setError("");
    try {
      const related = events.filter(event => event.company_id === activeEvent.company_id &&
        String(event.property_address || "").trim().toLowerCase() === String(activeEvent.property_address || "").trim().toLowerCase() &&
        (event.agent_id || null) === (activeEvent.agent_id || null));
      const targets = related.length ? related : [activeEvent];
      const { data: existingRows, error: existingError } = await supabase.from("dv_open_house_event_signs").select("event_id").in("event_id", targets.map(event => event.id)).eq("sign_location_id", location.id);
      if (existingError) throw existingError;
      const alreadyAdded = new Set((existingRows || []).map(row => row.event_id));
      const rows = targets.filter(event => !alreadyAdded.has(event.id)).map(event => ({ company_id: companyId, event_id: event.id, sign_location_id: location.id, sequence: event.id === activeEvent.id ? eventSigns.length + 1 : 999, status: "PLANNED" }));
      if (!rows.length) { setMessage("This sign location is already included in all dates for this property."); return; }
      const { data, error: insertError } = await supabase.from("dv_open_house_event_signs").insert(rows).select("*,location:dv_open_house_sign_locations(*)");
      if (insertError) throw insertError;
      const current = (data || []).find(row => row.event_id === activeEvent.id);
      if (current) setEventSigns(prev => [...prev, current]);
      setMessage("Sign location added to the checklist for every scheduled date at this property.");
    } catch (e) { setError(errorText(e)); }
    finally { setSaving(false); }
  }

  async function savePendingPoint() {
    if (!pendingPoint || !activeEvent || !supabase) return;
    setSaving(true); setError("");
    try {
      const { data: location, error: locationError } = await supabase.from("dv_open_house_sign_locations").insert({
        company_id: companyId, created_by: user.id, label: pointForm.label.trim() || "Directional sign",
        address: pendingPoint.address, latitude: pendingPoint.lat, longitude: pendingPoint.lng,
        direction: pointForm.direction.trim() || null, notes: pointForm.notes.trim() || null, active: true
      }).select("*").single();
      if (locationError) throw locationError;
      setLocations(prev => [location, ...prev]);
      setPendingPoint(null);
      await attachLocation(location);
    } catch (e) { setError(errorText(e)); setSaving(false); }
  }

  async function suggestIntersections() {
    if (!activeEvent || !propertyPoint || !window.google) return;
    setSuggesting(true); setError(""); setSuggestions([]);
    try {
      const { Place } = await window.google.maps.importLibrary("places");
      const { places = [] } = await Place.searchByText({
        textQuery: "major road intersections near " + activeEvent.property_address,
        fields: ["id", "displayName", "formattedAddress", "location"],
        locationBias: { center: propertyPoint, radius: 5000 },
        maxResultCount: 10,
        language: "en",
        region: "ca"
      });
      const seen = new Set();
      const options = places.map(place => {
        const location = place.location;
        const point = {
          lat: typeof location?.lat === "function" ? location.lat() : Number(location?.lat),
          lng: typeof location?.lng === "function" ? location.lng() : Number(location?.lng)
        };
        const name = typeof place.displayName === "string" ? place.displayName : place.displayName?.text || "Suggested intersection";
        return { id: place.id || name + ":" + point.lat + ":" + point.lng, name, address: place.formattedAddress || name, ...point, distance: distanceKm(propertyPoint, point) };
      }).filter(item => Number.isFinite(item.lat) && Number.isFinite(item.lng) && item.distance > .08 && item.distance <= 5)
        .filter(item => { if (seen.has(item.id)) return false; seen.add(item.id); return true; })
        .filter(item => !locations.some(saved => distanceKm(item, { lat: Number(saved.latitude), lng: Number(saved.longitude) }) < .06))
        .slice(0, 10);
      setSuggestions(options);
      if (!options.length) setMessage("No new nearby suggestions. Check your saved sign locations or add a pin manually.");
    } catch (e) {
      setError("Google Maps could not suggest nearby places: " + errorText(e) + " You can still tap the map to place signs manually.");
    } finally {
      setSuggesting(false);
    }
  }

  async function addSuggestion(item) {
    if (!activeEvent || !supabase) return;
    setSaving(true); setError("");
    try {
      const { data: location, error: insertError } = await supabase.from("dv_open_house_sign_locations").insert({
        company_id: companyId, created_by: user.id, label: "Suggested intersection",
        address: item.address, latitude: item.lat, longitude: item.lng, direction: item.name, active: true
      }).select("*").single();
      if (insertError) throw insertError;
      setLocations(prev => [location, ...prev]);
      setSuggestions(prev => prev.filter(x => x.id !== item.id));
      await attachLocation(location);
    } catch (e) { setError(errorText(e)); setSaving(false); }
  }

  async function updateSignStatus(item, status) {
    if (!supabase) return;
    setError("");
    const now = new Date().toISOString();
    const patch = { status, updated_at: now };
    if (status === "INSTALLED") { patch.installed_at = now; patch.installed_by = user.id; }
    if (status === "COLLECTED") { patch.collected_at = now; patch.collected_by = user.id; }
    if (status === "PLANNED") { patch.installed_at = null; patch.installed_by = null; patch.collected_at = null; patch.collected_by = null; }
    const { data, error: updateError } = await supabase.from("dv_open_house_event_signs").update(patch).eq("id", item.id).select("*,location:dv_open_house_sign_locations(*)").single();
    if (updateError) { setError(errorText(updateError)); return; }
    setEventSigns(prev => prev.map(row => row.id === item.id ? data : row));
    setMessage(status === "INSTALLED" ? "Sign marked as installed." : status === "COLLECTED" ? "Sign marked as collected." : "Sign returned to the plan.");
  }

  async function removeSign(item) {
    if (!window.confirm("Remove this sign from the open house plan? The saved location will remain in the shared location library.")) return;
    const { error: deleteError } = await supabase.from("dv_open_house_event_signs").delete().eq("id", item.id);
    if (deleteError) setError(errorText(deleteError));
    else setEventSigns(prev => prev.filter(row => row.id !== item.id));
  }

  async function uploadPhoto(item, file) {
    if (!file || !supabase) return;
    if (!file.type.startsWith("image/")) { setError("Please choose an image file."); return; }
    if (file.size > 8 * 1024 * 1024) { setError("Photo must be 8 MB or smaller."); return; }
    setPhotoBusyId(item.id); setError("");
    try {
      const ext = (file.name.split(".").pop() || "jpg").toLowerCase().replace(/[^a-z0-9]/g, "") || "jpg";
      const path = companyId + "/" + activeEvent.id + "/" + item.id + "-" + Date.now() + "." + ext;
      const { error: uploadError } = await supabase.storage.from(PHOTO_BUCKET).upload(path, file, { upsert: true, contentType: file.type });
      if (uploadError) throw uploadError;
      const { error: updateError } = await supabase.from("dv_open_house_event_signs").update({ photo_path: path, updated_at: new Date().toISOString() }).eq("id", item.id);
      if (updateError) throw updateError;
      const { data: signed } = await supabase.storage.from(PHOTO_BUCKET).createSignedUrl(path, 3600);
      setEventSigns(prev => prev.map(row => row.id === item.id ? { ...row, photo_path: path, photo_url: signed?.signedUrl || "" } : row));
      setMessage("Sign photo saved to the shared location record.");
    } catch (e) { setError(errorText(e)); }
    finally { setPhotoBusyId(""); }
  }

  async function openPhoto(path) {
    if (!path || !supabase) return;
    const { data, error: urlError } = await supabase.storage.from(PHOTO_BUCKET).createSignedUrl(path, 300);
    if (urlError) { setError(errorText(urlError)); return; }
    if (data?.signedUrl) window.open(data.signedUrl, "_blank", "noopener,noreferrer");
  }

  function openDirections() {
    if (!activeEvent || !eventSigns.length) return;
    const ordered = [...eventSigns].sort((a, b) => a.sequence - b.sequence);
    const origin = ordered[0].location.address;
    const destination = activeEvent.property_address;
    const waypoints = ordered.slice(1, 10).map(item => item.location.address);
    const url = "https://www.google.com/maps/dir/?api=1&origin=" + encodeURIComponent(origin) + "&destination=" + encodeURIComponent(destination) + (waypoints.length ? "&waypoints=" + encodeURIComponent("optimize:true|" + waypoints.join("|")) : "") + "&travelmode=driving";
    window.open(url, "_blank", "noopener,noreferrer");
  }

  async function drawRoute() {
    if (!activeEvent || !propertyPoint || !eventSigns.length || !window.google) return;
    setRouteBusy(true);
    setError("");
    try {
      const { Route: GoogleRoute } = await window.google.maps.importLibrary("routes");
      const ordered = [...eventSigns].sort((a, b) => a.sequence - b.sequence);
      const origin = { lat: Number(ordered[0].location.latitude), lng: Number(ordered[0].location.longitude) };
      const intermediates = ordered.slice(1, 10).map(item => ({
        location: { lat: Number(item.location.latitude), lng: Number(item.location.longitude) }
      }));
      const { routes = [] } = await GoogleRoute.computeRoutes({
        origin,
        destination: propertyPoint,
        intermediates,
        optimizeWaypointOrder: true,
        travelMode: "DRIVING",
        fields: ["path"]
      });
      if (!routes.length) throw new Error("Google Maps could not calculate a driving route for these sign locations.");
      routePolylinesRef.current.forEach(polyline => polyline.setMap(null));
      routePolylinesRef.current = routes[0].createPolylines();
      routePolylinesRef.current.forEach(polyline => polyline.setMap(mapRef.current));
      setMessage("Driving route displayed on the map. Use Get route for turn-by-turn navigation.");
    } catch (e) { setError(errorText(e)); }
    finally { setRouteBusy(false); }
  }

  const statusLabel = status => status === "INSTALLED" ? "Installed" : status === "COLLECTED" ? "Collected" : "To install";
  if (loading) return <div className="oh-loading"><LoaderCircle className="oh-spin"/> Loading Open House Signs…</div>;

  return <div className="oh-wrap">
    <div className="oh-heading">
      <div><div className="oh-eyebrow">DREAM VALLEY REALTY · FIELD TOOLS</div><h1>Open House Signs</h1><p>Plan sign locations, remember where they were placed, and reuse them at future open houses.</p></div>
      <button className="oh-primary" onClick={() => { setShowNewEvent(true); setError(""); }}><Plus size={16}/> New Open House</button>
    </div>
    {error && <div className="oh-alert oh-alert-error"><AlertTriangle size={17}/><span>{error}</span><button onClick={() => setError("")}><X size={15}/></button></div>}
    {message && <div className="oh-alert oh-alert-ok"><CheckCircle2 size={17}/><span>{message}</span><button onClick={() => setMessage("")}><X size={15}/></button></div>}
    {!MAPS_KEY && <div className="oh-key-warning"><AlertTriangle size={18}/><div><strong>Google Maps API key required</strong><p>Add <code>VITE_GOOGLE_MAPS_API_KEY</code> to the Railway environment and enable Maps JavaScript API, Places API and Geocoding API in Google Cloud. The map and address lookup will activate after redeployment.</p></div></div>}
    <div className="oh-layout">
      <aside className="oh-side">
        <div className="oh-side-head"><div><strong>Open houses</strong><span>{events.length} saved</span></div><button className="oh-icon-btn" title="Refresh" onClick={() => loadDirectories(companyId)}><RefreshCw size={15}/></button></div>
        <div className="oh-search"><Search size={15}/><input value={query} onChange={e => setQuery(e.target.value)} placeholder="Search property or agent"/></div>
        <div className="oh-event-list">
          {filteredEvents.length ? filteredEvents.map(event => <button key={event.id} className={"oh-event-row " + (event.id === activeEventId ? "selected" : "")} onClick={() => { setActiveEventId(event.id); setPendingPoint(null); setSuggestions([]); }}>
            <span className="oh-event-icon"><MapPin size={17}/></span><span className="oh-event-copy"><strong>{event.property_address}</strong><small>{prettyDate(event.event_date)} · {event.agent_name || "Agent"}</small></span><span className={"oh-dot " + String(event.status || "PLANNED").toLowerCase()} />
          </button>) : <div className="oh-empty-list">No open houses yet. Create one to start planning.</div>}
        </div>
        <div className="oh-side-foot"><History size={15}/> Saved sign locations are shared with active users in your brokerage.</div>
      </aside>
      <section className="oh-main">
        {activeEvent ? <>
          <div className="oh-event-header">
            <div><div className="oh-property-label">SELECTED OPEN HOUSE</div><h2>{activeEvent.property_address}</h2><div className="oh-meta"><span><CalendarDays size={14}/>{prettyDate(activeEvent.event_date)}</span><span><Clock3 size={14}/>{activeEvent.start_time ? activeEvent.start_time.slice(0,5) : "Time TBD"} – {activeEvent.end_time ? activeEvent.end_time.slice(0,5) : "Time TBD"}</span><span><MapPinned size={14}/>{eventSigns.length} sign locations</span></div></div>
            <div className="oh-event-actions"><button className="oh-secondary" onClick={() => { setTemplateEventId(activeEvent.id); setSelectedAgentId(activeEvent.agent_id || selectedAgentId); setEventForm({ property_address: activeEvent.property_address, start_time: activeEvent.start_time?.slice(0,5) || "13:00", end_time: activeEvent.end_time?.slice(0,5) || "16:00", notes: activeEvent.notes || "" }); setDateRows([{ event_date: "", start_time: activeEvent.start_time?.slice(0,5) || "13:00", end_time: activeEvent.end_time?.slice(0,5) || "16:00" }]); setShowNewEvent(true); setError(""); }}><Plus size={15}/> Add dates</button><button className="oh-secondary" onClick={suggestIntersections} disabled={suggesting || !mapReady}><Search size={15}/>{suggesting ? "Searching…" : "Suggest locations"}</button><button className="oh-primary" onClick={openDirections} disabled={!eventSigns.length}><Navigation size={15}/> Get route</button></div>
          </div>
          <div className="oh-tabs"><button className={selectedTab === "plan" ? "active" : ""} onClick={() => setSelectedTab("plan")}>Sign plan</button><button className={selectedTab === "saved" ? "active" : ""} onClick={() => setSelectedTab("saved")}>Saved nearby ({nearbyLocations.length})</button><button className={selectedTab === "suggestions" ? "active" : ""} onClick={() => setSelectedTab("suggestions")}>Suggestions ({suggestions.length})</button></div>
          <div className="oh-map-wrap">
            <div ref={mapElement} className="oh-map"/>
            {!mapReady && <div className="oh-map-overlay">{mapError ? <><AlertTriangle size={22}/><strong>Map unavailable</strong><span>{mapError}</span></> : <><LoaderCircle className="oh-spin"/><span>Loading Google Maps…</span></>}</div>}
            {mapReady && <div className="oh-map-tip"><MapPin size={14}/> Tap anywhere on the map to add a sign location</div>}
          </div>
          <div className="oh-map-actions"><span><i className="oh-legend-property"/> Property</span><span><i className="oh-legend-planned"/> Planned sign</span><span><i className="oh-legend-installed"/> Installed sign</span><button className="oh-secondary" onClick={drawRoute} disabled={!eventSigns.length || routeBusy}><Route size={15}/>{routeBusy ? "Drawing…" : "Show route on map"}</button></div>
          {pendingPoint && <div className="oh-pending-card"><div className="oh-pending-head"><div><strong>New sign location</strong><small>{pendingPoint.address}</small></div><button className="oh-icon-btn" onClick={() => setPendingPoint(null)}><X size={16}/></button></div><div className="oh-form-grid"><label>Sign label<input value={pointForm.label} onChange={e => setPointForm(p => ({ ...p, label: e.target.value }))}/></label><label>Direction / traffic flow<input value={pointForm.direction} onChange={e => setPointForm(p => ({ ...p, direction: e.target.value }))} placeholder="e.g. Facing westbound traffic"/></label><label className="full">Notes<textarea value={pointForm.notes} onChange={e => setPointForm(p => ({ ...p, notes: e.target.value }))} placeholder="Landmark, safe placement note, side of street…"/></label></div><div className="oh-card-actions"><button className="oh-secondary" onClick={() => setPendingPoint(null)}>Cancel</button><button className="oh-primary" onClick={savePendingPoint} disabled={saving}><Plus size={15}/> Save location & add to plan</button></div></div>}
          {selectedTab === "plan" && <div className="oh-sign-list"><div className="oh-section-head"><div><h3>Directional sign checklist</h3><p>Update each sign as you install it and collect it after the open house.</p></div><span>{eventSigns.filter(item => item.status === "INSTALLED").length} / {eventSigns.length} installed</span></div>
            {eventSigns.length ? eventSigns.map((item, index) => <div className="oh-sign-card" key={item.id}><div className="oh-number">{index + 1}</div><div className="oh-sign-details"><strong>{item.location.label || "Directional sign"}</strong><span>{item.location.address}</span>{item.location.direction && <small>{item.location.direction}</small>}{item.location.notes && <small>{item.location.notes}</small>}<div className="oh-sign-status"><span className={"oh-status " + item.status.toLowerCase()}>{statusLabel(item.status)}</span>{(item.photo_path || item.location.photo_path) && <button className="oh-text-btn" onClick={() => openPhoto(item.photo_path || item.location.photo_path)}>View photo</button>}</div></div><div className="oh-sign-tools"><label className="oh-photo-btn" title="Take a photo or choose one from your phone"><Camera size={15}/><span>{item.photo_path || item.location.photo_path ? "Change photo" : "Add photo"}</span><input type="file" accept="image/*" capture="environment" aria-label="Take a photo or choose a sign photo" onChange={e => { const file = e.target.files?.[0]; if (file) uploadPhoto(item, file); e.target.value = ""; }} disabled={photoBusyId === item.id}/></label>{photoBusyId === item.id && <LoaderCircle className="oh-spin"/>}{item.status === "PLANNED" ? <button className="oh-small-primary" onClick={() => updateSignStatus(item, "INSTALLED")}>Installed</button> : item.status === "INSTALLED" ? <button className="oh-small-success" onClick={() => updateSignStatus(item, "COLLECTED")}>Collected</button> : <button className="oh-small-muted" onClick={() => updateSignStatus(item, "PLANNED")}>Reset</button>}<button type="button" className="oh-remove-sign" title="Remove this sign from the current open house plan" onClick={() => removeSign(item)}><Trash2 size={15}/><span>Remove</span></button></div></div>) : <div className="oh-empty-list">No signs added yet. Tap the map, or reuse a saved location from the Saved nearby tab.</div>}
          </div>}
          {selectedTab === "saved" && <div className="oh-sign-list"><div className="oh-section-head"><div><h3>Saved locations near this property</h3><p>Locations within 5 km of the open house. These stay in the shared brokerage library.</p></div><span>{nearbyLocations.length} saved</span></div>{nearbyLocations.length ? nearbyLocations.map(location => <div className="oh-library-row" key={location.id}><div className="oh-library-pin"><MapPin size={17}/></div><div className="oh-library-copy"><strong>{location.label}</strong><span>{location.address}</span><small>{distanceKm(propertyPoint, { lat: Number(location.latitude), lng: Number(location.longitude) }).toFixed(1)} km from property{location.direction ? " · " + location.direction : ""}</small></div><button className="oh-small-primary" disabled={saving || eventSigns.some(item => item.sign_location_id === location.id)} onClick={() => attachLocation(location)}>{eventSigns.some(item => item.sign_location_id === location.id) ? "Added" : "Add to plan"}</button></div>) : <div className="oh-empty-list">No saved locations within 5 km yet. Add pins to build your shared sign library.</div>}</div>}
          {selectedTab === "suggestions" && <div className="oh-sign-list"><div className="oh-section-head"><div><h3>Google Maps suggestions</h3><p>Review each suggestion before adding it. Google results may be nearby places rather than safe sign locations.</p></div><button className="oh-secondary" onClick={suggestIntersections} disabled={suggesting || !mapReady}><RefreshCw size={14}/> Refresh suggestions</button></div>{suggestions.length ? suggestions.map(item => <div className="oh-library-row" key={item.id}><div className="oh-library-pin"><MapPin size={17}/></div><div className="oh-library-copy"><strong>{item.name}</strong><span>{item.address}</span><small>{item.distance.toFixed(1)} km away · Check local sign rules and visibility before placing</small></div><button className="oh-small-primary" onClick={() => addSuggestion(item)} disabled={saving}>Add</button></div>) : <div className="oh-empty-list">No suggestions yet. Select “Suggest locations” to ask Google Maps for nearby intersections.</div>}</div>}
        </> : <div className="oh-no-event"><MapPinned size={42}/><h2>Plan your first open house</h2><p>Enter a property address to map the route and save directional sign locations for future use.</p><button className="oh-primary" onClick={() => setShowNewEvent(true)}><Plus size={16}/> Create open house</button></div>}
      </section>
    </div>
    {showNewEvent && <div className="oh-modal-backdrop"><form className="oh-modal" onSubmit={createEvent}><div className="oh-modal-head"><div><strong>New open house</strong><span>Start with the property address and event details.</span></div><button type="button" className="oh-icon-btn" onClick={() => setShowNewEvent(false)}><X size={17}/></button></div><div className="oh-modal-body">{adminMode && <label className="full">Assign open house to agent<select required value={selectedAgentId} onChange={e => setSelectedAgentId(e.target.value)}><option value="">Select an agent</option>{agents.map(agent => <option key={agent.id} value={agent.id}>{agent.name || [agent.first_name, agent.last_name].filter(Boolean).join(" ") || agent.email}</option>)}</select></label>}<label className="full">Property address<input autoFocus required value={eventForm.property_address} onChange={e => setEventForm(f => ({ ...f, property_address: e.target.value }))} placeholder="Street address, city, province, postal code"/></label><div className="oh-date-schedule"><div className="oh-date-schedule-head"><strong>Open house dates</strong><button type="button" className="oh-secondary" onClick={() => setDateRows(rows => [...rows, { event_date: "", start_time: rows[rows.length-1]?.start_time || "13:00", end_time: rows[rows.length-1]?.end_time || "16:00" }])}><Plus size={14}/> Add another date</button></div>{dateRows.map((row,index) => <div className="oh-date-row" key={index}><div className="oh-date-row-title"><strong>Date {index+1}</strong>{dateRows.length>1 && <button type="button" className="oh-text-btn" onClick={() => setDateRows(rows => rows.filter((_,i)=>i!==index))}>Remove</button>}</div><label>Date<input required type="date" value={row.event_date} onChange={e => setDateRows(rows => rows.map((item,i)=>i===index?{...item,event_date:e.target.value}:item))}/></label><div className="oh-form-grid"><label>Start time<input type="time" value={row.start_time} onChange={e => setDateRows(rows => rows.map((item,i)=>i===index?{...item,start_time:e.target.value}:item))}/></label><label>End time<input type="time" value={row.end_time} onChange={e => setDateRows(rows => rows.map((item,i)=>i===index?{...item,end_time:e.target.value}:item))}/></label></div></div>)}</div><label className="full">Notes<textarea value={eventForm.notes} onChange={e => setEventForm(f => ({ ...f, notes: e.target.value }))} placeholder="Optional instructions"/></label><div className="oh-modal-note"><AlertTriangle size={15}/> Sign suggestions are starting points only. Check municipal rules and place signs where they do not obstruct sidewalks, roads or sightlines.</div></div><div className="oh-modal-actions"><button type="button" className="oh-secondary" onClick={() => setShowNewEvent(false)}>Cancel</button><button type="submit" className="oh-primary" disabled={saving}>{saving ? "Saving…" : "Save open house"}</button></div></form></div>}
  </div>;
}
