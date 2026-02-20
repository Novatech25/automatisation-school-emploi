-- ============================================================
-- MISE A JOUR: Ajout du support school_id optionnel
-- pour la fonction de notification
-- ============================================================

-- Modifier la fonction existante pour accepter school_id optionnel
CREATE OR REPLACE FUNCTION send_room_assignment_notifications_rpc(
    p_notification_window INTEGER,
    p_session_date DATE DEFAULT CURRENT_DATE,
    p_school_id UUID DEFAULT NULL  -- NOUVEAU: filtre par école optionnel
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_total_notifications INTEGER := 0;
    v_assignment RECORD;
    v_time_from TIME;
    v_time_to TIME;
    v_session_start TIMESTAMPTZ;
BEGIN
    -- Calculer la fenêtre de temps (±5 minutes pour la marge)
    v_time_from := (CURRENT_TIME + (p_notification_window - 5) * INTERVAL '1 minute')::TIME;
    v_time_to := (CURRENT_TIME + (p_notification_window + 5) * INTERVAL '1 minute')::TIME;

    -- Récupérer les attributions à notifier
    FOR v_assignment IN
        SELECT 
            ra.*,
            r.name AS room_name,
            s.name AS subject_name,
            t.first_name || ' ' || t.last_name AS teacher_name,
            c.name AS class_name,
            ss.start_time,
            ss.end_time
        FROM room_assignments ra
        JOIN schedule_slots ss ON ra.schedule_slot_id = ss.id
        JOIN rooms r ON ra.room_id = r.id
        JOIN classes c ON ss.class_id = c.id
        JOIN subjects s ON ss.subject_id = s.id
        JOIN teachers t ON ss.teacher_id = t.id
        WHERE ra.status = 'published'
        AND ra.session_date = p_session_date
        AND ss.start_time BETWEEN v_time_from AND v_time_to
        -- Filtre par école si spécifié
        AND (p_school_id IS NULL OR ra.school_id = p_school_id)
        -- Éviter les doublons de notification
        AND NOT EXISTS (
            SELECT 1 FROM notifications n
            WHERE n.related_id = ra.id::TEXT
            AND n.type = 'room_assignment_reminder'
            AND n.metadata->>'window' = p_notification_window::TEXT
            AND n.created_at > NOW() - INTERVAL '1 hour'
        )
    LOOP
        -- Calculer l'heure exacte de la session
        v_session_start := (p_session_date || ' ' || v_assignment.start_time)::TIMESTAMPTZ;

        -- Créer notification pour l'enseignant
        INSERT INTO notifications (
            user_id,
            type,
            title,
            message,
            related_id,
            metadata,
            school_id
        )
        SELECT 
            u.id,
            'room_assignment_reminder',
            CASE 
                WHEN p_notification_window = 60 THEN '⏰ Rappel: Cours dans 1h'
                WHEN p_notification_window = 15 THEN '🔔 Bientôt: Cours dans 15min'
                ELSE '📚 Rappel de cours'
            END,
            format(
                'Votre cours de %s avec %s commence à %s en salle %s',
                v_assignment.subject_name,
                v_assignment.class_name,
                to_char(v_assignment.start_time, 'HH24:MI'),
                v_assignment.room_name
            ),
            v_assignment.id::TEXT,
            jsonb_build_object(
                'room_assignment_id', v_assignment.id,
                'room_name', v_assignment.room_name,
                'subject_name', v_assignment.subject_name,
                'class_name', v_assignment.class_name,
                'start_time', v_assignment.start_time,
                'window', p_notification_window,
                'session_start', v_session_start
            ),
            v_assignment.school_id
        FROM users u
        WHERE u.email = v_assignment.teacher_email
        ON CONFLICT DO NOTHING;

        -- Créer notification pour la classe (étudiants)
        INSERT INTO notifications (
            user_id,
            type,
            title,
            message,
            related_id,
            metadata,
            school_id
        )
        SELECT 
            u.id,
            'room_assignment_reminder',
            CASE 
                WHEN p_notification_window = 60 THEN '⏰ Prochain cours dans 1h'
                WHEN p_notification_window = 15 THEN '🔔 Cours imminent (15min)'
                ELSE '📚 Rappel de cours'
            END,
            format(
                'Le cours de %s commence à %s en salle %s (Prof: %s)',
                v_assignment.subject_name,
                to_char(v_assignment.start_time, 'HH24:MI'),
                v_assignment.room_name,
                v_assignment.teacher_name
            ),
            v_assignment.id::TEXT,
            jsonb_build_object(
                'room_assignment_id', v_assignment.id,
                'room_name', v_assignment.room_name,
                'subject_name', v_assignment.subject_name,
                'teacher_name', v_assignment.teacher_name,
                'start_time', v_assignment.start_time,
                'window', p_notification_window
            ),
            v_assignment.school_id
        FROM users u
        JOIN enrollments e ON u.student_id = e.student_id
        WHERE e.class_id = v_assignment.class_id
        AND e.status = 'active'
        ON CONFLICT DO NOTHING;

        v_total_notifications := v_total_notifications + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'success', TRUE,
        'notification_window', p_notification_window,
        'session_date', p_session_date,
        'school_id', p_school_id,
        'notifications_sent', v_total_notifications,
        'time_window', format('%s - %s', v_time_from::TEXT, v_time_to::TEXT)
    );
END;
$$;

-- Mettre à jour le commentaire
COMMENT ON FUNCTION send_room_assignment_notifications_rpc(INTEGER, DATE, UUID) IS 
    'Envoie les rappels T-60 ou T-15. Option school_id pour filtrer par école.';

-- Réaccorder les permissions
GRANT EXECUTE ON FUNCTION send_room_assignment_notifications_rpc(INTEGER, DATE, UUID) 
    TO anon, authenticated, service_role;
