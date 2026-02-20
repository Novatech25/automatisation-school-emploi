-- ============================================================
-- FONCTIONS MULTI-ECOLE POUR ROOM ASSIGNMENT
-- Traite automatiquement toutes les écoles activées
-- ============================================================

-- Fonction pour récupérer toutes les écoles avec room assignment activé
CREATE OR REPLACE FUNCTION get_schools_with_room_assignment_enabled()
RETURNS TABLE (
    school_id UUID,
    school_name TEXT,
    auto_publish BOOLEAN,
    notification_enabled BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        s.id,
        s.name,
        COALESCE((s.settings->'roomAssignment'->>'autoPublish')::BOOLEAN, FALSE),
        COALESCE((s.settings->'roomAssignment'->>'notificationsEnabled')::BOOLEAN, TRUE)
    FROM schools s
    WHERE 
        -- Module activé (par défaut TRUE si non défini)
        COALESCE((s.settings->'roomAssignment'->>'enabled')::BOOLEAN, TRUE)
        AND s.status = 'active';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction principale multi-école : calcul pour toutes les écoles
CREATE OR REPLACE FUNCTION calculate_room_assignments_all_schools_rpc(
    p_session_date DATE DEFAULT (CURRENT_DATE + INTERVAL '1 day')::DATE
)
RETURNS JSONB AS $$
DECLARE
    v_school RECORD;
    v_result JSONB;
    v_all_results JSONB := '[]'::JSONB;
    v_success_count INTEGER := 0;
    v_error_count INTEGER := 0;
BEGIN
    -- Boucle sur toutes les écoles avec room assignment activé
    FOR v_school IN 
        SELECT * FROM get_schools_with_room_assignment_enabled()
    LOOP
        BEGIN
            -- Appeler la fonction de calcul pour cette école
            SELECT calculate_room_assignments_rpc(
                v_school.school_id,
                p_session_date,
                NULL,  -- Tous les schedules
                v_school.auto_publish
            ) INTO v_result;
            
            -- Ajouter le résultat
            v_all_results := v_all_results || jsonb_build_object(
                'school_id', v_school.school_id,
                'school_name', v_school.school_name,
                'status', 'success',
                'result', v_result
            );
            
            v_success_count := v_success_count + 1;
            
        EXCEPTION WHEN OTHERS THEN
            -- Log l'erreur mais continue avec les autres écoles
            v_all_results := v_all_results || jsonb_build_object(
                'school_id', v_school.school_id,
                'school_name', v_school.school_name,
                'status', 'error',
                'error', SQLERRM
            );
            
            v_error_count := v_error_count + 1;
        END;
    END LOOP;
    
    RETURN jsonb_build_object(
        'success', TRUE,
        'session_date', p_session_date,
        'schools_processed', v_success_count,
        'schools_failed', v_error_count,
        'total_schools', v_success_count + v_error_count,
        'details', v_all_results
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction multi-école pour les notifications
CREATE OR REPLACE FUNCTION send_room_assignment_notifications_all_schools_rpc(
    p_notification_window INTEGER DEFAULT 60,
    p_session_date DATE DEFAULT CURRENT_DATE
)
RETURNS JSONB AS $$
DECLARE
    v_school RECORD;
    v_result JSONB;
    v_all_results JSONB := '[]'::JSONB;
    v_success_count INTEGER := 0;
    v_error_count INTEGER := 0;
BEGIN
    -- Boucle sur toutes les écoles avec notifications activées
    FOR v_school IN 
        SELECT * FROM get_schools_with_room_assignment_enabled()
        WHERE notification_enabled = TRUE
    LOOP
        BEGIN
            -- Appeler la fonction de notification pour cette école
            SELECT send_room_assignment_notifications_rpc(
                p_notification_window,
                p_session_date,
                v_school.school_id  -- Filtre par école
            ) INTO v_result;
            
            v_all_results := v_all_results || jsonb_build_object(
                'school_id', v_school.school_id,
                'school_name', v_school.school_name,
                'status', 'success',
                'result', v_result
            );
            
            v_success_count := v_success_count + 1;
            
        EXCEPTION WHEN OTHERS THEN
            v_all_results := v_all_results || jsonb_build_object(
                'school_id', v_school.school_id,
                'school_name', v_school.school_name,
                'status', 'error',
                'error', SQLERRM
            );
            
            v_error_count := v_error_count + 1;
        END;
    END LOOP;
    
    RETURN jsonb_build_object(
        'success', TRUE,
        'notification_window', p_notification_window,
        'session_date', p_session_date,
        'schools_notified', v_success_count,
        'schools_failed', v_error_count,
        'details', v_all_results
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour nettoyer les anciennes attributions (toutes écoles)
CREATE OR REPLACE FUNCTION cleanup_old_room_assignments_all_schools_rpc(
    p_days_to_keep INTEGER DEFAULT 30
)
RETURNS JSONB AS $$
DECLARE
    v_deleted_count INTEGER := 0;
BEGIN
    DELETE FROM room_assignments
    WHERE session_date < (CURRENT_DATE - INTERVAL '1 day' * p_days_to_keep)
      AND status IN ('draft', 'cancelled');
    
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    
    RETURN jsonb_build_object(
        'success', TRUE,
        'deleted_count', v_deleted_count,
        'days_threshold', p_days_to_keep
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Accorder les permissions pour les fonctions RPC
GRANT EXECUTE ON FUNCTION calculate_room_assignments_all_schools_rpc(DATE) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION send_room_assignment_notifications_all_schools_rpc(INTEGER, DATE) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION cleanup_old_room_assignments_all_schools_rpc(INTEGER) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION get_schools_with_room_assignment_enabled() TO anon, authenticated, service_role;
